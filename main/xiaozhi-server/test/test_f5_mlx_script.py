import subprocess
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
SCRIPT_PATH = SCRIPT_DIR / "start-f5-mlx.sh"
COMPOSE_PATH = SCRIPT_DIR / "docker-compose.local-f5-mlx.yml"
SERVER_PATH = SCRIPT_DIR / "f5_mlx_openai_server.py"


def test_f5_mlx_script_exists_and_is_valid_bash():
    assert SCRIPT_PATH.exists()

    result = subprocess.run(
        ["bash", "-n", str(SCRIPT_PATH)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr


def test_f5_mlx_script_defaults_match_expected_runtime():
    content = SCRIPT_PATH.read_text(encoding="utf-8")

    assert "CONDA_ENV_NAME=\"${F5_MLX_CONDA_ENV_NAME:-f5_tts_mlx}\"" in content
    assert "CONDA_PYTHON_VERSION=\"${F5_MLX_PYTHON_VERSION:-3.11}\"" in content
    assert "F5_MLX_PIP_SPECS=\"${F5_MLX_PIP_SPECS:-f5-tts-mlx fastapi uvicorn[standard] pydantic}" in content
    assert "MODEL_NAME=\"${F5_MLX_MODEL_NAME:-lucasnewman/f5-tts-mlx}\"" in content
    assert "F5_MLX_ENDPOINT=\"${F5_MLX_ENDPOINT:-http://127.0.0.1:${F5_MLX_PORT}}\"" in content
    assert "config/assets/wakeup_words.wav" in content
    assert "F5_MLX_XIAOZHI_CONFIG_VOICE" in content
    assert "F5_MLX_DEFAULT_REF_AUDIO" in content
    assert "F5_MLX_DEFAULT_REF_TEXT" in content
    assert "F5_MLX_VOICE_DIR" in content
    assert "start_detached_process" in content
    assert "start_watchdog" in content
    assert "stop_watchdog" in content
    assert "refresh_watchdog_for_start" in content
    assert "stop_competing_watchdogs" in content
    assert "launch_model" in content
    assert "probe_model_audio" in content
    assert "start)" in content
    assert "stop)" in content
    assert "watchdog)" in content


def test_f5_mlx_compose_points_xiaozhi_to_host_f5_service():
    assert COMPOSE_PATH.exists()

    content = COMPOSE_PATH.read_text(encoding="utf-8")

    assert "http://host.docker.internal:8002/v1/audio/speech" in content
    assert "lucasnewman/f5-tts-mlx" in content
    assert "voice_01" in content
    assert "XIAOZHI_TTS_LANG_CODE: ${XIAOZHI_TTS_LANG_CODE:-zh}" in content


def test_f5_mlx_openai_server_exposes_required_endpoints():
    assert SERVER_PATH.exists()

    content = SERVER_PATH.read_text(encoding="utf-8")

    assert "from starlette.background import BackgroundTask" in content
    assert "from fastapi.background import BackgroundTask" not in content
    assert "from f5_tts_mlx.cfm import F5TTS" in content
    assert "F5TTS.from_pretrained" in content
    assert "@app.post(\"/v1/audio/speech\")" in content
    assert "@app.get(\"/v1/models\")" in content
    assert "@app.post(\"/v1/models\")" in content
    assert "ref_audio" in content
    assert "ref_text" in content


def test_f5_mlx_openai_server_estimates_total_duration_like_f5_cli():
    content = SERVER_PATH.read_text(encoding="utf-8")

    assert "duration_in_frames = ref_audio_len + int(" in content
    assert "return duration_in_frames / FRAMES_PER_SEC" in content


def test_f5_mlx_script_enables_estimated_duration_by_default():
    content = SCRIPT_PATH.read_text(encoding="utf-8")

    assert "ESTIMATE_DURATION=\"${F5_MLX_ESTIMATE_DURATION:-true}\"" in content
    assert "export F5_MLX_ESTIMATE_DURATION=\"${ESTIMATE_DURATION}\"" in content
