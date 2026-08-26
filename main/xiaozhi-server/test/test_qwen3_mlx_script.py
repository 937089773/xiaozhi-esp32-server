import subprocess
from pathlib import Path


SCRIPT_DIR = Path(__file__).resolve().parents[1]
SCRIPT_PATH = SCRIPT_DIR / "start-qwen3-mlx.sh"
COMPOSE_PATH = SCRIPT_DIR / "docker-compose.local-qwen3-mlx.yml"


def test_qwen3_mlx_script_exists_and_is_valid_bash():
    assert SCRIPT_PATH.exists()

    result = subprocess.run(
        ["bash", "-n", str(SCRIPT_PATH)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0, result.stderr


def test_qwen3_mlx_script_defaults_match_expected_runtime():
    content = SCRIPT_PATH.read_text(encoding="utf-8")

    assert "CONDA_ENV_NAME=\"${QWEN3_XINFERENCE_CONDA_ENV_NAME:-xinference_python3.12}\"" in content
    assert "MODEL_NAME=\"${QWEN3_XINFERENCE_MODEL_NAME:-Qwen3-TTS-12Hz-0.6B-CustomVoice}\"" in content
    assert "MODEL_ENGINE=\"${QWEN3_XINFERENCE_MODEL_ENGINE:-MLX}\"" in content
    assert "MODEL_DEVICE=\"${QWEN3_XINFERENCE_MODEL_DEVICE:-cpu}\"" in content
    assert "VOICE_RAW=\"${QWEN3_XINFERENCE_VOICE:-${XIAOZHI_TTS_VOICE:-serena}}\"" in content
    assert "aiden|dylan|eric|ono_anna|ryan|serena|sohee|uncle_fu|vivian" in content
    assert "NUMBA_CACHE_DIR=\"${NUMBA_CACHE_DIR:-${DATA_DIR}/numba-cache}\"" in content
    assert "MLX_AUDIO_PIP_SPEC=\"${QWEN3_MLX_AUDIO_PIP_SPEC:-}\"" in content
    assert "QWEN_TTS_PIP_SPEC=\"${QWEN3_QWEN_TTS_PIP_SPEC:-qwen-tts}\"" in content
    assert "QWEN_TTS_RUNTIME_PIP_SPECS=\"${QWEN3_QWEN_TTS_RUNTIME_PIP_SPECS:-transformers==4.57.3" in content
    assert "QWEN_TTS_INSTALL_NO_DEPS=\"${QWEN3_QWEN_TTS_INSTALL_NO_DEPS:-true}\"" in content
    assert "--no-deps" in content
    assert "\"qwen_tts\"" in content
    assert "XINFERENCE_AUTH_ADVANCED=\"${XINFERENCE_AUTH_ADVANCED:-false}\"" in content
    assert "kwargs[\"device\"] = model_device" in content
    assert "-w '%{http_code}'" in content
    assert "REPLACE_STALE_SERVER=\"${QWEN3_XINFERENCE_REPLACE_STALE_SERVER:-true}\"" in content
    assert "server_uses_expected_env" in content
    assert "RECREATE_MISMATCHED_CONTAINER=\"${QWEN3_XIAOZHI_RECREATE_MISMATCHED_CONTAINER:-true}\"" in content
    assert "container_matches_expected_tts_env" in content
    assert "WATCHDOG_PID_FILE=\"${QWEN3_WATCHDOG_PID_FILE:-${DATA_DIR}/qwen3-watchdog.pid}\"" in content
    assert "WATCHDOG_RESTART_ON_START=\"${QWEN3_WATCHDOG_RESTART_ON_START:-true}\"" in content
    assert "start_new_session=True" in content
    assert "start_detached_process" in content
    assert "start_watchdog" in content
    assert "stop_watchdog" in content
    assert "refresh_watchdog_for_start" in content
    assert "run_watchdog" in content
    assert "Qwen3 TTS 音频探测失败" in content
    assert "start)" in content
    assert "stop)" in content
    assert "watchdog)" in content
    assert "docker compose" in content
    assert "terminate_model" in content


def test_qwen3_mlx_compose_points_xiaozhi_to_host_xinference():
    assert COMPOSE_PATH.exists()

    content = COMPOSE_PATH.read_text(encoding="utf-8")

    assert "http://host.docker.internal:9997/v1/audio/speech" in content
    assert "Qwen3-TTS-12Hz-0.6B-CustomVoice" in content
    assert "serena" in content
