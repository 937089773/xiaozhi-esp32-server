#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

XINFERENCE_HOST="${XINFERENCE_HOST:-0.0.0.0}"
XINFERENCE_PORT="${XINFERENCE_PORT:-9997}"
XINFERENCE_ENDPOINT="${XINFERENCE_ENDPOINT:-http://127.0.0.1:${XINFERENCE_PORT}}"
XINFERENCE_HOME_DIR="${XINFERENCE_HOME:-${SCRIPT_DIR}/data/kokoro-xinference/home}"
DATA_DIR="${KOKORO_XINFERENCE_DATA_DIR:-${SCRIPT_DIR}/data/kokoro-xinference}"
CONDA_ENV_NAME="${KOKORO_XINFERENCE_CONDA_ENV_NAME:-python12-xiaozhi-tts}"
CONDA_ENV_DIR="${KOKORO_XINFERENCE_CONDA_ENV_DIR:-}"
CONDA_PYTHON_VERSION="${KOKORO_XINFERENCE_PYTHON_VERSION:-3.12}"
CONDA_EXE="${KOKORO_XINFERENCE_CONDA:-$(command -v conda || true)}"
CONDA_CREATE_ARGS="${KOKORO_XINFERENCE_CONDA_CREATE_ARGS:---override-channels -c conda-forge}"
LOG_DIR="${KOKORO_XINFERENCE_LOG_DIR:-${DATA_DIR}/logs}"
PID_FILE="${KOKORO_XINFERENCE_PID_FILE:-${DATA_DIR}/xinference-local.pid}"
LOG_FILE="${KOKORO_XINFERENCE_LOG_FILE:-${LOG_DIR}/xinference-local.log}"
START_TIMEOUT="${KOKORO_XINFERENCE_START_TIMEOUT:-300}"
PROBE_TIMEOUT="${KOKORO_XINFERENCE_PROBE_TIMEOUT:-60}"
XINFERENCE_PIP_SPEC="${XINFERENCE_PIP_SPEC:-xinference==1.9.1}"
XINFERENCE_DISABLE_METRICS="${XINFERENCE_DISABLE_METRICS:-1}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"

MODEL_NAME="${KOKORO_XINFERENCE_MODEL_NAME:-Kokoro-82M-zh-MLX}"
MODEL_UID="${KOKORO_XINFERENCE_MODEL_UID:-Kokoro-82M-zh-MLX}"
MODEL_FAMILY="${KOKORO_XINFERENCE_MODEL_FAMILY:-Kokoro-MLX}"
MODEL_ID="${KOKORO_XINFERENCE_MODEL_ID:-1038lab/Kokoro-82M-zh-MLX}"
MODEL_CACHE_ID="${MODEL_ID//\//--}"
DEFAULT_LOCAL_MODEL_URI="${DATA_DIR}/models/${MODEL_NAME}"
MODEL_URI="${KOKORO_XINFERENCE_MODEL_URI:-}"
if [ -z "${MODEL_URI}" ] && [ -d "${DEFAULT_LOCAL_MODEL_URI}" ]; then
  MODEL_URI="${DEFAULT_LOCAL_MODEL_URI}"
fi
DOWNLOAD_HUB="${KOKORO_XINFERENCE_DOWNLOAD_HUB:-modelscope}"
REGISTER_CUSTOM_MODEL="${KOKORO_XINFERENCE_REGISTER_CUSTOM_MODEL:-true}"
FORCE_REGISTER_MODEL="${KOKORO_XINFERENCE_FORCE_REGISTER_MODEL:-false}"
VOICE="${KOKORO_XINFERENCE_VOICE:-${XIAOZHI_TTS_VOICE:-zf_001}}"
LANG_CODE="${KOKORO_XINFERENCE_LANG_CODE:-${XIAOZHI_TTS_LANG_CODE:-z}}"
FORMAT="${KOKORO_XINFERENCE_FORMAT:-${XIAOZHI_TTS_FORMAT:-wav}}"
SPEED="${KOKORO_XINFERENCE_SPEED:-${XIAOZHI_TTS_SPEED:-1}}"

COMPOSE_FILE="${XIAOZHI_MLX_COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.local-kokoro-mlx.yml}"
CONTAINER_NAME="${XIAOZHI_SERVER_CONTAINER:-xiaozhi-esp32-server}"
HOST_TTS_URL="${XINFERENCE_ENDPOINT}/v1/audio/speech"
CONTAINER_TTS_URL="${XINFERENCE_DOCKER_TTS_URL:-http://host.docker.internal:${XINFERENCE_PORT}/v1/audio/speech}"

info() {
  printf '[INFO] %s\n' "$*"
}

warn() {
  printf '[WARN] %s\n' "$*" >&2
}

die() {
  printf '[ERROR] %s\n' "$*" >&2
  exit 1
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

find_python3() {
  local env_py
  env_py="$(env_python_if_exists || true)"
  if [ -n "${env_py}" ]; then
    printf '%s\n' "${env_py}"
    return
  fi

  for candidate in python3.12 python3.11 python3.10 python3; do
    if command_exists "${candidate}"; then
      command -v "${candidate}"
      return
    fi
  done

  die "未找到 python3，请先安装 Python 3.10-3.12。"
}

docker_compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    printf 'docker compose'
    return
  fi
  if command_exists docker-compose; then
    printf 'docker-compose'
    return
  fi
  die "未找到 docker compose 或 docker-compose。"
}

conda_env_prefix() {
  if [ -n "${CONDA_ENV_DIR}" ]; then
    printf '%s\n' "${CONDA_ENV_DIR}"
    return 0
  fi

  [ -n "${CONDA_EXE}" ] || return 1
  [ -x "${CONDA_EXE}" ] || return 1

  "${CONDA_EXE}" env list | awk -v name="${CONDA_ENV_NAME}" '
    $1 == name { print $NF; found = 1 }
    END { if (!found) exit 1 }
  '
}

env_python_if_exists() {
  local prefix
  prefix="$(conda_env_prefix 2>/dev/null || true)"
  if [ -n "${prefix}" ] && [ -x "${prefix}/bin/python" ]; then
    printf '%s/bin/python\n' "${prefix}"
  fi
}

env_python() {
  local env_py
  env_py="$(env_python_if_exists || true)"
  [ -n "${env_py}" ] || die "未找到 Conda 环境：${CONDA_ENV_NAME}"
  printf '%s\n' "${env_py}"
}

env_bin() {
  local prefix
  prefix="$(conda_env_prefix 2>/dev/null || true)"
  [ -n "${prefix}" ] || die "未找到 Conda 环境：${CONDA_ENV_NAME}"
  printf '%s/bin/%s\n' "${prefix}" "$1"
}

make_probe_body() {
  MODEL_UID="${MODEL_UID}" \
    VOICE="${VOICE}" \
    LANG_CODE="${LANG_CODE}" \
    FORMAT="${FORMAT}" \
    SPEED="${SPEED}" \
    "$(find_python3)" - <<'PY'
import json
import os

payload = {
    "model": os.environ["MODEL_UID"],
    "input": "你好",
    "voice": os.environ["VOICE"],
    "response_format": os.environ["FORMAT"],
    "speed": float(os.environ["SPEED"]),
    "stream": False,
    "lang_code": os.environ["LANG_CODE"],
}
print(json.dumps(payload, ensure_ascii=False))
PY
}

server_available() {
  command_exists curl || die "未找到 curl，无法检测 Xinference 服务。"

  curl -sS \
    --max-time 5 \
    "${XINFERENCE_ENDPOINT}/v1/models" \
    >/dev/null 2>&1
}

probe_model() {
  command_exists curl || die "未找到 curl，无法检测 Kokoro Xinference 模型。"

  local tmp_file http_code
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/kokoro-xinference-probe.XXXXXX")"
  http_code="$(
    curl -sS \
      --max-time "${PROBE_TIMEOUT}" \
      -o "${tmp_file}" \
      -w '%{http_code}' \
      -H 'accept: application/json' \
      -H 'Content-Type: application/json' \
      -X POST "${HOST_TTS_URL}" \
      --data "$(make_probe_body)" 2>/dev/null || true
  )"

  if [ "${http_code}" = "200" ] && [ -s "${tmp_file}" ]; then
    rm -f "${tmp_file}"
    return 0
  fi

  rm -f "${tmp_file}"
  return 1
}

pid_is_alive() {
  [ -f "${PID_FILE}" ] || return 1
  local pid
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" >/dev/null 2>&1
}

port_is_listening() {
  if command_exists lsof; then
    lsof -nP -iTCP:"${XINFERENCE_PORT}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  if command_exists nc; then
    nc -z 127.0.0.1 "${XINFERENCE_PORT}" >/dev/null 2>&1
    return
  fi
  return 1
}

ensure_conda_env() {
  mkdir -p "${DATA_DIR}" "${LOG_DIR}" "${XINFERENCE_HOME_DIR}"
  if [ -n "$(env_python_if_exists || true)" ]; then
    info "使用 Conda 环境：$(conda_env_prefix)"
    return
  fi

  [ -n "${CONDA_EXE}" ] || die "未找到 conda，请先安装 Conda 或设置 KOKORO_XINFERENCE_CONDA。"
  [ -x "${CONDA_EXE}" ] || die "Conda 不可执行：${CONDA_EXE}"

  if [ -n "${CONDA_ENV_DIR}" ]; then
    info "创建 Xinference Conda 路径环境：${CONDA_ENV_DIR}"
    # shellcheck disable=SC2086
    "${CONDA_EXE}" create -y ${CONDA_CREATE_ARGS} -p "${CONDA_ENV_DIR}" "python=${CONDA_PYTHON_VERSION}" pip
  else
    info "创建 Xinference Conda 命名环境：${CONDA_ENV_NAME}"
    # shellcheck disable=SC2086
    "${CONDA_EXE}" create -y ${CONDA_CREATE_ARGS} -n "${CONDA_ENV_NAME}" "python=${CONDA_PYTHON_VERSION}" pip
  fi
}

deps_ready() {
  XINFERENCE_PIP_SPEC="${XINFERENCE_PIP_SPEC}" "$(env_python)" - <<'PY' >/dev/null 2>&1
import importlib.util
import os
import re
import sys
from importlib.metadata import PackageNotFoundError, version

required = [
    "xinference",
    "mlx_audio",
    "misaki",
    "phonemizer",
    "espeakng_loader",
]
missing = [name for name in required if importlib.util.find_spec(name) is None]
if missing:
    sys.exit(1)

spec = os.environ["XINFERENCE_PIP_SPEC"]
match = re.search(r"==\s*([^\s;]+)", spec)
if match:
    try:
        installed = version("xinference")
    except PackageNotFoundError:
        sys.exit(1)
    if installed != match.group(1):
        sys.exit(1)

sys.exit(0)
PY
}

ensure_deps() {
  if deps_ready && [ -x "$(env_bin xinference-local)" ]; then
    return
  fi

  info "安装 Xinference + Kokoro MLX 依赖。首次安装会比较久。"
  "$(env_python)" -m pip install -U pip
  "$(env_python)" -m pip install -U \
    "${XINFERENCE_PIP_SPEC}" \
    mlx-audio \
    "misaki[zh]" \
    phonemizer-fork \
    espeakng-loader \
    soundfile
}

wait_for_server() {
  local start_ts now
  start_ts="$(date +%s)"
  while true; do
    if server_available; then
      return
    fi

    if [ -f "${PID_FILE}" ] && ! pid_is_alive; then
      die "Xinference 服务进程已退出，请查看日志：${LOG_FILE}"
    fi

    now="$(date +%s)"
    if [ $((now - start_ts)) -ge "${START_TIMEOUT}" ]; then
      die "等待 Xinference 服务启动超时，请查看日志：${LOG_FILE}"
    fi

    sleep 2
  done
}

start_xinference_server() {
  if server_available; then
    info "Xinference 服务已可用：${XINFERENCE_ENDPOINT}"
    return
  fi

  if port_is_listening; then
    die "端口 ${XINFERENCE_PORT} 已被占用，但 ${XINFERENCE_ENDPOINT} 不可用。请检查占用进程。"
  fi

  info "启动 Xinference 服务：${XINFERENCE_ENDPOINT}"
  XINFERENCE_HOME="${XINFERENCE_HOME_DIR}" \
  XINFERENCE_DISABLE_METRICS="${XINFERENCE_DISABLE_METRICS}" \
  HF_ENDPOINT="${HF_ENDPOINT}" \
  HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET}" \
    nohup "$(env_bin xinference-local)" \
      --host "${XINFERENCE_HOST}" \
      --port "${XINFERENCE_PORT}" \
      >>"${LOG_FILE}" 2>&1 &
  echo "$!" >"${PID_FILE}"
  wait_for_server
}

register_custom_model() {
  if [ "${REGISTER_CUSTOM_MODEL}" != "true" ]; then
    return
  fi

  info "确认 Xinference 自定义模型注册：${MODEL_NAME} -> ${MODEL_ID}"
  ENDPOINT="${XINFERENCE_ENDPOINT}" \
    MODEL_NAME="${MODEL_NAME}" \
    MODEL_FAMILY="${MODEL_FAMILY}" \
    MODEL_ID="${MODEL_ID}" \
    MODEL_URI="${MODEL_URI}" \
    DOWNLOAD_HUB="${DOWNLOAD_HUB}" \
    FORCE_REGISTER_MODEL="${FORCE_REGISTER_MODEL}" \
    "$(env_python)" - <<'PY'
import json
import os
import sys

from xinference.client import Client


endpoint = os.environ["ENDPOINT"]
model_name = os.environ["MODEL_NAME"]
model_family = os.environ["MODEL_FAMILY"]
model_id = os.environ["MODEL_ID"]
model_uri = os.environ.get("MODEL_URI") or None
download_hub = os.environ.get("DOWNLOAD_HUB") or "huggingface"
force_register = os.environ.get("FORCE_REGISTER_MODEL") == "true"

client = Client(endpoint)


def contains_registration(registrations, name):
    if isinstance(registrations, dict):
        if name in registrations:
            return True
        return any(contains_registration(value, name) for value in registrations.values())
    if isinstance(registrations, list):
        return any(contains_registration(item, name) for item in registrations)
    if isinstance(registrations, str):
        return registrations == name
    return False


try:
    registrations = client.list_model_registrations(model_type="audio")
except Exception:
    registrations = []

if force_register and contains_registration(registrations, model_name):
    client.unregister_model(model_type="audio", model_name=model_name)
    registrations = []

if contains_registration(registrations, model_name):
    print(f"model registration exists: {model_name}")
    sys.exit(0)

model = {
    "version": 2,
    "model_name": model_name,
    "model_description": "Kokoro Chinese MLX TTS model for Apple Silicon.",
    "model_family": model_family,
    "model_ability": ["text2audio", "text2audio_zero_shot"],
    "multilingual": True,
    "model_id": model_id,
    "model_hub": download_hub,
    "model_uri": model_uri,
    "model_revision": None,
    "model_src": {
        download_hub: {
            "model_id": model_id,
        }
    },
    "default_model_config": {
        "lang_code": "z",
    },
    "virtualenv": {
        "packages": [
            "mlx-audio",
            "mlx-lm",
            "misaki[zh]",
            "phonemizer-fork",
            "espeakng-loader",
            "soundfile",
            "#system_numpy#",
        ],
        "inherit_pip_config": True,
    },
}

try:
    client.register_model(
        model_type="audio",
        model=json.dumps(model, ensure_ascii=False),
        persist=True,
    )
except Exception as exc:
    raise SystemExit(f"register Xinference model failed: {exc}") from exc

print(f"registered model: {model_name}")
PY
}

launch_model() {
  if probe_model; then
    info "Xinference 中的 ${MODEL_UID} 已可合成音频，跳过模型启动。"
    return
  fi

  register_custom_model

  info "启动 Xinference 模型：name=${MODEL_NAME}, uid=${MODEL_UID}"
  ENDPOINT="${XINFERENCE_ENDPOINT}" \
    MODEL_NAME="${MODEL_NAME}" \
    MODEL_UID="${MODEL_UID}" \
    DOWNLOAD_HUB="${DOWNLOAD_HUB}" \
    LANG_CODE="${LANG_CODE}" \
    MODEL_URI="${MODEL_URI}" \
    "$(env_python)" - <<'PY'
import os
import sys

from xinference.client import Client


client = Client(os.environ["ENDPOINT"])
kwargs = {
    "model_name": os.environ["MODEL_NAME"],
    "model_type": "audio",
    "model_uid": os.environ["MODEL_UID"],
    "download_hub": os.environ.get("DOWNLOAD_HUB") or "modelscope",
    "lang_code": os.environ.get("LANG_CODE") or "z",
    "compile": False,
}
model_uri = os.environ.get("MODEL_URI")
if model_uri:
    kwargs["model_path"] = model_uri

try:
    uid = client.launch_model(**kwargs)
except Exception as exc:
    message = str(exc)
    if "already" in message.lower() and os.environ["MODEL_UID"] in message:
        print(f"model already launched: {os.environ['MODEL_UID']}")
        sys.exit(0)
    raise SystemExit(f"launch Xinference model failed: {exc}") from exc

print(f"launched model uid: {uid}")
PY

  local start_ts now
  start_ts="$(date +%s)"
  while true; do
    if probe_model; then
      info "Xinference 模型 ${MODEL_UID} 启动完成。"
      return
    fi

    now="$(date +%s)"
    if [ $((now - start_ts)) -ge "${START_TIMEOUT}" ]; then
      die "等待 Xinference 模型 ${MODEL_UID} 可用超时，请查看日志：${LOG_FILE}"
    fi

    sleep 3
  done
}

start_inference() {
  if probe_model; then
    info "Xinference + ${MODEL_UID} 已可用，跳过 inference 启动。"
    return
  fi

  ensure_conda_env
  ensure_deps
  start_xinference_server
  launch_model
}

container_is_running() {
  docker ps \
    --filter "name=^/${CONTAINER_NAME}$" \
    --filter "status=running" \
    --format '{{.Names}}' | grep -qx "${CONTAINER_NAME}"
}

start_xiaozhi_server() {
  command_exists docker || die "未找到 docker。"

  if container_is_running; then
    info "Docker 容器 ${CONTAINER_NAME} 已运行，跳过启动。"
    return
  fi

  [ -f "${COMPOSE_FILE}" ] || die "未找到 Compose 文件：${COMPOSE_FILE}"

  export XIAOZHI_TTS_MODE="${XIAOZHI_TTS_MODE:-local}"
  export XIAOZHI_TTS_PROVIDER="${XIAOZHI_TTS_PROVIDER:-CustomTTS}"
  export XIAOZHI_TTS_URL="${XIAOZHI_TTS_URL:-${CONTAINER_TTS_URL}}"
  export XIAOZHI_TTS_MODEL="${XIAOZHI_TTS_MODEL:-${MODEL_UID}}"
  export XIAOZHI_TTS_VOICE="${XIAOZHI_TTS_VOICE:-${VOICE}}"
  export XIAOZHI_TTS_FORMAT="${XIAOZHI_TTS_FORMAT:-${FORMAT}}"
  export XIAOZHI_TTS_SPEED="${XIAOZHI_TTS_SPEED:-${SPEED}}"
  export XIAOZHI_TTS_STREAM="${XIAOZHI_TTS_STREAM:-false}"
  export XIAOZHI_TTS_LANG_CODE="${XIAOZHI_TTS_LANG_CODE:-${LANG_CODE}}"

  info "启动 Docker 版 ${CONTAINER_NAME}。"
  local compose_cmd
  compose_cmd="$(docker_compose_cmd)"
  # shellcheck disable=SC2086
  ${compose_cmd} -f "${COMPOSE_FILE}" up -d --build xiaozhi-esp32-server
}

main() {
  info "工作目录：${REPO_ROOT}"
  start_inference
  start_xiaozhi_server
  info "启动流程完成。"
  info "Xinference endpoint：${XINFERENCE_ENDPOINT}"
  info "TTS endpoint for Docker：${CONTAINER_TTS_URL}"
  info "Model UID：${MODEL_UID}"
  info "Xinference 日志：${LOG_FILE}"
}

main "$@"
