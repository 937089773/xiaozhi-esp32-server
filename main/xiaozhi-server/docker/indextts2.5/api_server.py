import os
import shutil
import subprocess
import tempfile
import threading
from pathlib import Path
from typing import List, Optional

from fastapi import FastAPI, HTTPException
from fastapi.background import BackgroundTask
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel


app = FastAPI(title="Xiaozhi IndexTTS2.5 API")

_engine = None
_engine_lock = threading.Lock()
_infer_lock = threading.Lock()


class SpeechRequest(BaseModel):
    model: Optional[str] = None
    input: Optional[str] = None
    text: Optional[str] = None
    voice: Optional[str] = None
    response_format: Optional[str] = None
    speed: Optional[float] = None
    stream: Optional[bool] = False
    lang: Optional[str] = None
    lang_code: Optional[str] = None
    spk_audio_prompt: Optional[str] = None
    emo_audio_prompt: Optional[str] = None
    emo_alpha: Optional[float] = 1.0
    emo_vector: Optional[List[float]] = None
    use_emo_text: Optional[bool] = False
    emo_text: Optional[str] = None
    use_random: Optional[bool] = False
    duration_factor: Optional[float] = None
    interval_silence: Optional[int] = 200
    max_text_tokens_per_segment: Optional[int] = 120
    text_normalization: Optional[bool] = True


class IndexStreamRequest(BaseModel):
    text: str
    character: Optional[str] = None
    lang: Optional[str] = None
    lang_code: Optional[str] = None
    response_format: Optional[str] = "pcm"


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def _env_float(name: str, default: float) -> float:
    value = os.environ.get(name)
    if value is None or value == "":
        return default
    try:
        return float(value)
    except ValueError:
        return default


def _clamp(value: float, min_value: float, max_value: float) -> float:
    return max(min_value, min(max_value, value))


def _get_engine():
    global _engine
    if _engine is None:
        with _engine_lock:
            if _engine is None:
                from indextts.infer_v2_5 import IndexTTS2

                model_dir = Path(
                    os.environ.get("INDEXTTS_MODEL_DIR", "/opt/index-tts/checkpoints")
                )
                cfg_path = os.environ.get(
                    "INDEXTTS_CFG_PATH", str(model_dir / "config.yaml")
                )
                device = os.environ.get("INDEXTTS_DEVICE") or None
                _engine = IndexTTS2(
                    cfg_path=cfg_path,
                    model_dir=str(model_dir),
                    use_bf16=_env_bool("INDEXTTS_USE_BF16", True),
                    device=device,
                    use_cuda_kernel=_env_bool("INDEXTTS_USE_CUDA_KERNEL", True),
                    use_deepspeed=_env_bool("INDEXTTS_USE_DEEPSPEED", False),
                    use_accel=_env_bool("INDEXTTS_USE_ACCEL", False),
                    use_torch_compile=_env_bool("INDEXTTS_USE_TORCH_COMPILE", False),
                    use_qwen_emo=_env_bool("INDEXTTS_USE_QWEN_EMO", False),
                )
    return _engine


def _normalize_lang(lang: Optional[str]) -> str:
    default_lang = os.environ.get("INDEXTTS_DEFAULT_LANG", "ZH")
    value = (lang or default_lang).strip()
    aliases = {
        "z": "ZH",
        "zh": "ZH",
        "cn": "ZH",
        "chinese": "ZH",
        "中文": "ZH",
        "en": "EN",
        "english": "EN",
        "英语": "EN",
        "ja": "JA",
        "jp": "JA",
        "japanese": "JA",
        "日语": "JA",
        "es": "ES",
        "spanish": "ES",
        "西班牙语": "ES",
        "ar": "AR",
        "arabic": "AR",
        "阿拉伯语": "AR",
    }
    return aliases.get(value.lower(), value.upper())


def _resolve_audio_prompt(value: Optional[str], *, required: bool) -> Optional[str]:
    if value is None or value == "":
        if required:
            value = os.environ.get("INDEXTTS_DEFAULT_SPK_AUDIO")
        else:
            return None
    if value is None or value == "":
        if required:
            raise HTTPException(status_code=400, detail="Missing reference audio")
        return None

    raw_path = Path(value)
    voice_dir = Path(os.environ.get("INDEXTTS_VOICE_DIR", "/opt/index-tts/voices"))
    examples_dir = Path(
        os.environ.get("INDEXTTS_EXAMPLES_DIR", "/opt/index-tts/examples")
    )

    candidates = []
    if raw_path.is_absolute():
        candidates.append(raw_path)
    else:
        candidates.extend(
            [
                Path.cwd() / raw_path,
                voice_dir / raw_path,
                examples_dir / raw_path,
            ]
        )
        if raw_path.suffix == "":
            candidates.extend(
                [
                    voice_dir / f"{value}.wav",
                    examples_dir / f"{value}.wav",
                ]
            )

    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)

    if required:
        checked = ", ".join(str(path) for path in candidates)
        raise HTTPException(
            status_code=400,
            detail=f"Reference audio not found. Checked: {checked}",
        )
    return None


def _normalize_format(value: Optional[str], default_format: str = "wav") -> str:
    fmt = (value or default_format).strip().lower().lstrip(".")
    if fmt == "mpeg":
        fmt = "mp3"
    if fmt not in {"wav", "mp3", "pcm"}:
        raise HTTPException(status_code=400, detail=f"Unsupported audio format: {fmt}")
    return fmt


def _duration_factor(request: SpeechRequest) -> float:
    if request.duration_factor is not None:
        return _clamp(float(request.duration_factor), 0.5, 2.0)

    speed = request.speed
    if speed is None:
        speed = _env_float("INDEXTTS_DEFAULT_SPEED", 1.0)
    if speed <= 0:
        speed = 1.0
    return _clamp(1.0 / float(speed), 0.5, 2.0)


def _convert_audio(input_wav: Path, output_format: str) -> Path:
    if output_format == "wav":
        return input_wav

    output_path = input_wav.with_suffix(f".{output_format}")
    command = [
        "ffmpeg",
        "-nostdin",
        "-y",
        "-i",
        str(input_wav),
    ]
    if output_format == "mp3":
        command.extend(["-codec:a", "libmp3lame", str(output_path)])
    else:
        command.extend(
            [
                "-f",
                "s16le",
                "-acodec",
                "pcm_s16le",
                "-ac",
                "1",
                "-ar",
                "24000",
                str(output_path),
            ]
        )

    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise HTTPException(
            status_code=500,
            detail=f"Audio conversion failed: {result.stderr.strip()}",
        )
    return output_path


def _media_type(output_format: str) -> str:
    if output_format == "wav":
        return "audio/wav"
    if output_format == "mp3":
        return "audio/mpeg"
    return "application/octet-stream"


def _render_speech(request: SpeechRequest, default_format: str) -> FileResponse:
    text = request.input or request.text
    if not text:
        raise HTTPException(status_code=400, detail="Missing input text")
    if request.stream:
        raise HTTPException(status_code=400, detail="Streaming output is not supported")

    output_format = _normalize_format(request.response_format, default_format)
    spk_audio_prompt = _resolve_audio_prompt(
        request.spk_audio_prompt or request.voice, required=True
    )
    emo_audio_prompt = _resolve_audio_prompt(request.emo_audio_prompt, required=False)
    lang = _normalize_lang(request.lang or request.lang_code)

    tmp_dir = Path(tempfile.mkdtemp(prefix="indextts-"))
    output_wav = tmp_dir / "speech.wav"

    try:
        with _infer_lock:
            _get_engine().infer(
                spk_audio_prompt=spk_audio_prompt,
                text=text,
                output_path=str(output_wav),
                lang=lang,
                emo_audio_prompt=emo_audio_prompt,
                emo_alpha=1.0 if request.emo_alpha is None else request.emo_alpha,
                emo_vector=request.emo_vector,
                use_emo_text=bool(request.use_emo_text),
                emo_text=request.emo_text,
                use_random=bool(request.use_random),
                interval_silence=(
                    200 if request.interval_silence is None else request.interval_silence
                ),
                max_text_tokens_per_segment=(
                    120
                    if request.max_text_tokens_per_segment is None
                    else request.max_text_tokens_per_segment
                ),
                duration_factor=_duration_factor(request),
                text_normalization=(
                    True
                    if request.text_normalization is None
                    else bool(request.text_normalization)
                ),
            )

        if not output_wav.is_file() or output_wav.stat().st_size == 0:
            raise HTTPException(status_code=500, detail="IndexTTS returned empty audio")

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


@app.get("/health")
def health():
    return JSONResponse({"status": "ok"})


@app.post("/v1/audio/speech")
def openai_style_speech(request: SpeechRequest):
    default_format = os.environ.get("INDEXTTS_DEFAULT_FORMAT", "wav")
    return _render_speech(request, default_format)


@app.post("/audio/speech")
def speech(request: SpeechRequest):
    default_format = os.environ.get("INDEXTTS_DEFAULT_FORMAT", "wav")
    return _render_speech(request, default_format)


@app.post("/tts")
def index_stream_tts(request: IndexStreamRequest):
    speech_request = SpeechRequest(
        input=request.text,
        voice=request.character,
        lang=request.lang,
        lang_code=request.lang_code,
        response_format=request.response_format or "pcm",
    )
    return _render_speech(speech_request, "pcm")
