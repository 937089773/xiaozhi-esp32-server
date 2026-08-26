import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from typing import Any, Optional

import mlx.core as mx
import numpy as np
import soundfile as sf
from fastapi import FastAPI, HTTPException, Response
from fastapi.responses import FileResponse, JSONResponse
from f5_tts_mlx.cfm import F5TTS
from f5_tts_mlx.utils import convert_char_to_pinyin
from pydantic import BaseModel
from starlette.background import BackgroundTask


SAMPLE_RATE = 24_000
HOP_LENGTH = 256
FRAMES_PER_SEC = SAMPLE_RATE / HOP_LENGTH
TARGET_RMS = 0.1

app = FastAPI(title="Xiaozhi F5-TTS MLX API")
_model_lock = threading.Lock()
_infer_lock = threading.Lock()
_models: dict[tuple[str, Optional[int]], F5TTS] = {}


class SpeechRequest(BaseModel):
    model: Optional[str] = None
    input: Optional[str] = None
    text: Optional[str] = None
    voice: Optional[str] = None
    response_format: Optional[str] = None
    speed: Optional[float] = None
    stream: Optional[bool] = False
    lang_code: Optional[str] = None
    ref_audio: Optional[str] = None
    ref_text: Optional[str] = None
    duration: Optional[float] = None
    estimate_duration: Optional[bool] = None
    steps: Optional[int] = None
    method: Optional[str] = None
    cfg: Optional[float] = None
    sway_coef: Optional[float] = None
    seed: Optional[int] = None
    q: Optional[int] = None
    kwargs: Optional[Any] = None


def _env_value(name: str, default: Optional[str] = None) -> Optional[str]:
    value = os.environ.get(name)
    if value is None:
        return default
    value = value.strip()
    return value if value else default


def _env_bool(name: str, default: bool = False) -> bool:
    value = _env_value(name)
    if value is None:
        return default
    return value.lower() in {"1", "true", "yes", "on"}


def _env_int(name: str, default: Optional[int] = None) -> Optional[int]:
    value = _env_value(name)
    if value is None:
        return default
    try:
        return int(value)
    except ValueError:
        return default


def _env_float(name: str, default: float) -> float:
    value = _env_value(name)
    if value is None:
        return default
    try:
        return float(value)
    except ValueError:
        return default


def _extra_kwargs(request: SpeechRequest) -> dict[str, Any]:
    raw = request.kwargs
    if raw is None:
        return {}
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str) and raw.strip():
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise HTTPException(status_code=400, detail="Invalid kwargs JSON") from exc
        if not isinstance(data, dict):
            raise HTTPException(status_code=400, detail="kwargs must be a JSON object")
        return data
    return {}


def _default_model_name() -> str:
    return _env_value("F5_MLX_MODEL_NAME", "lucasnewman/f5-tts-mlx") or "lucasnewman/f5-tts-mlx"


def _request_value(
    request: SpeechRequest,
    extras: dict[str, Any],
    field: str,
    default: Any = None,
) -> Any:
    value = getattr(request, field)
    if value not in (None, ""):
        return value
    value = extras.get(field)
    if value not in (None, ""):
        return value
    return default


def _quantization_bits(request: Optional[SpeechRequest] = None, extras: Optional[dict[str, Any]] = None) -> Optional[int]:
    raw_value = None
    if request is not None and request.q is not None:
        raw_value = request.q
    elif extras and extras.get("q") not in (None, ""):
        raw_value = extras["q"]
    else:
        return _env_int("F5_MLX_QUANTIZATION_BITS", 4)

    try:
        value = int(raw_value)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail="q must be 4, 8, or empty") from exc
    if value not in (4, 8):
        raise HTTPException(status_code=400, detail="q must be 4, 8, or empty")
    return value


def _load_model(model_name: str, quantization_bits: Optional[int]) -> F5TTS:
    key = (model_name, quantization_bits)
    with _model_lock:
        model = _models.get(key)
        if model is None:
            model = F5TTS.from_pretrained(
                model_name,
                quantization_bits=quantization_bits,
            )
            _models[key] = model
        return model


def _candidate_audio_paths(value: str) -> list[Path]:
    raw_path = Path(value)
    voice_dir = Path(_env_value("F5_MLX_VOICE_DIR", "data/f5-mlx/voices") or "data/f5-mlx/voices")
    candidates: list[Path] = []

    if raw_path.is_absolute():
        candidates.append(raw_path)
    else:
        candidates.append(Path.cwd() / raw_path)
        candidates.append(voice_dir / raw_path)
        if raw_path.suffix == "":
            candidates.append(voice_dir / f"{value}.wav")
    return candidates


def _resolve_ref_audio(request: SpeechRequest, extras: dict[str, Any]) -> Path:
    value = _request_value(request, extras, "ref_audio")
    if not value:
        value = _request_value(request, extras, "voice")
    if not value:
        value = _env_value("F5_MLX_DEFAULT_REF_AUDIO")

    checked: list[str] = []
    if value:
        for candidate in _candidate_audio_paths(str(value)):
            checked.append(str(candidate))
            if candidate.is_file():
                return candidate

    default_ref = _env_value("F5_MLX_DEFAULT_REF_AUDIO")
    if default_ref:
        default_path = Path(default_ref)
        checked.append(str(default_path))
        if default_path.is_file():
            return default_path

    detail = "F5-TTS requires reference audio. "
    detail += "Put voice_01.wav under F5_MLX_VOICE_DIR or set F5_MLX_DEFAULT_REF_AUDIO."
    if checked:
        detail += " Checked: " + ", ".join(dict.fromkeys(checked))
    raise HTTPException(status_code=400, detail=detail)


def _resolve_ref_text(request: SpeechRequest, extras: dict[str, Any]) -> str:
    value = _request_value(request, extras, "ref_text")
    if value:
        return str(value)

    voice = _request_value(request, extras, "voice")
    voice_dir = Path(_env_value("F5_MLX_VOICE_DIR", "data/f5-mlx/voices") or "data/f5-mlx/voices")
    checked: list[str] = []
    if voice:
        voice_path = Path(str(voice))
        if not voice_path.is_absolute() and voice_path.suffix == "":
            candidate = voice_dir / f"{voice}.txt"
            checked.append(str(candidate))
            if candidate.is_file():
                return candidate.read_text(encoding="utf-8").strip()

    default_text = _env_value("F5_MLX_DEFAULT_REF_TEXT")
    if default_text:
        return default_text

    default_text_file = _env_value("F5_MLX_DEFAULT_REF_TEXT_FILE")
    if default_text_file:
        candidate = Path(default_text_file)
        checked.append(str(candidate))
        if candidate.is_file():
            return candidate.read_text(encoding="utf-8").strip()

    detail = "F5-TTS requires reference text. "
    detail += "Put voice_01.txt under F5_MLX_VOICE_DIR or set F5_MLX_DEFAULT_REF_TEXT."
    if checked:
        detail += " Checked: " + ", ".join(dict.fromkeys(checked))
    raise HTTPException(status_code=400, detail=detail)


def _read_reference_audio(path: Path) -> mx.array:
    audio, sample_rate = sf.read(str(path), always_2d=False)
    if sample_rate != SAMPLE_RATE:
        raise HTTPException(
            status_code=400,
            detail=f"Reference audio must be {SAMPLE_RATE}Hz WAV. Got {sample_rate}Hz: {path}",
        )
    if getattr(audio, "ndim", 1) != 1:
        raise HTTPException(
            status_code=400,
            detail=f"Reference audio must be mono WAV: {path}",
        )

    ref_audio = mx.array(audio)
    rms = mx.sqrt(mx.mean(mx.square(ref_audio)))
    if float(rms.item()) > 0 and float(rms.item()) < TARGET_RMS:
        ref_audio = ref_audio * TARGET_RMS / rms
    return ref_audio


def _split_text(text: str) -> list[str]:
    parts = re.split(r"([.!?;:。！？；：])", text)
    sentences: list[str] = []
    for index in range(0, len(parts) - 1, 2):
        sentence = (parts[index] + parts[index + 1]).strip()
        if sentence:
            sentences.append(sentence)
    tail = parts[-1].strip() if parts else ""
    if tail:
        sentences.append(tail)
    return sentences or [text.strip()]


def _estimated_duration(ref_audio: mx.array, ref_text: str, gen_text: str, speed: float) -> float:
    ref_audio_len = ref_audio.shape[0] // HOP_LENGTH
    pause_punctuation = r"。，、；：？！.!?;:"
    ref_text_len = len(ref_text.encode("utf-8")) + 3 * len(re.findall(pause_punctuation, ref_text))
    gen_text_len = len(gen_text.encode("utf-8")) + 3 * len(re.findall(pause_punctuation, gen_text))
    if ref_text_len <= 0:
        return max(1.0, len(gen_text) / 4)
    duration_in_frames = ref_audio_len + int(ref_audio_len / ref_text_len * gen_text_len / max(speed, 0.1))
    return duration_in_frames / FRAMES_PER_SEC


def _normalize_format(value: Optional[str]) -> str:
    output_format = (value or _env_value("F5_MLX_DEFAULT_FORMAT", "wav") or "wav").strip().lower().lstrip(".")
    if output_format == "mpeg":
        output_format = "mp3"
    if output_format not in {"wav", "mp3", "flac", "ogg", "opus", "pcm"}:
        raise HTTPException(status_code=400, detail=f"Unsupported audio format: {output_format}")
    return output_format


def _media_type(output_format: str) -> str:
    if output_format == "wav":
        return "audio/wav"
    if output_format == "mp3":
        return "audio/mpeg"
    if output_format in {"flac", "ogg", "opus"}:
        return f"audio/{output_format}"
    return "application/octet-stream"


def _convert_audio(input_wav: Path, output_format: str) -> Path:
    if output_format == "wav":
        return input_wav

    output_path = input_wav.with_suffix(f".{output_format}")
    command = ["ffmpeg", "-nostdin", "-y", "-i", str(input_wav)]
    if output_format == "pcm":
        command.extend(["-f", "s16le", "-acodec", "pcm_s16le", "-ac", "1", "-ar", str(SAMPLE_RATE), str(output_path)])
    else:
        command.append(str(output_path))

    try:
        result = subprocess.run(command, capture_output=True, text=True, check=False)
    except FileNotFoundError as exc:
        raise HTTPException(status_code=500, detail="ffmpeg is required for non-wav output") from exc
    if result.returncode != 0:
        raise HTTPException(status_code=500, detail=f"Audio conversion failed: {result.stderr.strip()}")
    return output_path


def _generate_wav(request: SpeechRequest, output_path: Path) -> None:
    extras = _extra_kwargs(request)
    text = request.input or request.text
    if not text:
        raise HTTPException(status_code=400, detail="Missing input text")
    if request.stream:
        raise HTTPException(status_code=400, detail="Streaming output is not supported")

    model_name = request.model or _default_model_name()
    speed = float(_request_value(request, extras, "speed", _env_float("F5_MLX_SPEED", 1.0)))
    duration = _request_value(request, extras, "duration")
    estimate_duration = bool(_request_value(request, extras, "estimate_duration", _env_bool("F5_MLX_ESTIMATE_DURATION", True)))
    steps = int(_request_value(request, extras, "steps", _env_int("F5_MLX_STEPS", 8)))
    method = str(_request_value(request, extras, "method", _env_value("F5_MLX_METHOD", "rk4")))
    cfg = float(_request_value(request, extras, "cfg", _env_float("F5_MLX_CFG", 2.0)))
    sway_coef = float(_request_value(request, extras, "sway_coef", _env_float("F5_MLX_SWAY_COEF", -1.0)))
    seed = _request_value(request, extras, "seed", _env_int("F5_MLX_SEED"))
    seed = None if seed in (None, "") else int(seed)
    quantization_bits = _quantization_bits(request, extras)

    ref_audio_path = _resolve_ref_audio(request, extras)
    ref_text = _resolve_ref_text(request, extras)
    ref_audio = _read_reference_audio(ref_audio_path)

    if method not in {"euler", "midpoint", "rk4"}:
        raise HTTPException(status_code=400, detail="method must be euler, midpoint, or rk4")

    with _infer_lock:
        model = _load_model(model_name, quantization_bits)
        output_parts = []
        for sentence in _split_text(text):
            duration_frames = None
            if duration not in (None, ""):
                duration_frames = int(float(duration) * FRAMES_PER_SEC)
            elif estimate_duration:
                duration_frames = int(_estimated_duration(ref_audio, ref_text, sentence, speed) * FRAMES_PER_SEC)

            tokens = convert_char_to_pinyin([ref_text + " " + sentence])
            wave, _ = model.sample(
                mx.expand_dims(ref_audio, axis=0),
                text=tokens,
                duration=duration_frames,
                steps=steps,
                method=method,
                speed=speed,
                cfg_strength=cfg,
                sway_sampling_coef=sway_coef,
                seed=seed,
            )
            wave = wave[ref_audio.shape[0] :]
            mx.eval(wave)
            output_parts.append(wave)

        if not output_parts:
            raise HTTPException(status_code=400, detail="No text to synthesize")
        output_audio = output_parts[0] if len(output_parts) == 1 else mx.concatenate(output_parts, axis=0)
        sf.write(str(output_path), np.array(output_audio), SAMPLE_RATE)


@app.get("/health")
def health():
    return JSONResponse({"status": "ok", "loaded_models": len(_models)})


@app.get("/v1/models")
def list_models():
    data = []
    for model_name, quantization_bits in _models:
        data.append(
            {
                "id": model_name,
                "object": "model",
                "created": int(time.time()),
                "owned_by": "f5-tts-mlx",
                "quantization_bits": quantization_bits,
            }
        )
    return {"object": "list", "data": data}


@app.post("/v1/models")
def add_model(model_name: Optional[str] = None, q: Optional[int] = None):
    name = model_name or _default_model_name()
    quantization_bits = q if q is not None else _env_int("F5_MLX_QUANTIZATION_BITS", 4)
    if quantization_bits not in (None, 4, 8):
        raise HTTPException(status_code=400, detail="q must be 4, 8, or empty")
    _load_model(name, quantization_bits)
    return {"status": "success", "message": f"Model {name} added successfully"}


@app.delete("/v1/models")
def remove_model(model_name: Optional[str] = None, q: Optional[int] = None):
    name = model_name or _default_model_name()
    quantization_bits = q if q is not None else _env_int("F5_MLX_QUANTIZATION_BITS", 4)
    key = (name, quantization_bits)
    with _model_lock:
        if key in _models:
            del _models[key]
            return Response(status_code=204)
    raise HTTPException(status_code=404, detail=f"Model '{name}' is not loaded")


@app.post("/v1/audio/speech")
def create_speech(request: SpeechRequest):
    output_format = _normalize_format(request.response_format)
    tmp_dir = Path(tempfile.mkdtemp(prefix="f5-mlx-"))
    output_wav = tmp_dir / "speech.wav"
    try:
        _generate_wav(request, output_wav)
        if not output_wav.is_file() or output_wav.stat().st_size == 0:
            raise HTTPException(status_code=500, detail="F5-TTS returned empty audio")
        response_path = _convert_audio(output_wav, output_format)
        return FileResponse(
            response_path,
            media_type=_media_type(output_format),
            filename=f"speech.{output_format}",
            background=BackgroundTask(shutil.rmtree, str(tmp_dir), ignore_errors=True),
        )
    except Exception:
        shutil.rmtree(str(tmp_dir), ignore_errors=True)
        raise


def main():
    parser = argparse.ArgumentParser(description="F5-TTS MLX OpenAI-compatible API")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8002)
    parser.add_argument("--log-dir", default="logs")
    args = parser.parse_args()

    Path(args.log_dir).mkdir(parents=True, exist_ok=True)
    import uvicorn

    uvicorn.run("f5_mlx_openai_server:app", host=args.host, port=args.port, workers=1)


if __name__ == "__main__":
    main()
