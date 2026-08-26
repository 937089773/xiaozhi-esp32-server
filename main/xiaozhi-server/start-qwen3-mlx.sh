#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="${SCRIPT_DIR}/$(basename "${BASH_SOURCE[0]}")"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DEFAULT_CONDA_EXE="$(command -v conda || true)"
if [ -z "${DEFAULT_CONDA_EXE}" ]; then
  for candidate in \
    /opt/anaconda3/bin/conda \
    /opt/miniconda3/bin/conda \
    "${HOME}/anaconda3/bin/conda" \
    "${HOME}/miniconda3/bin/conda" \
    "${HOME}/mambaforge/bin/conda"; do
    if [ -x "${candidate}" ]; then
      DEFAULT_CONDA_EXE="${candidate}"
      break
    fi
  done
fi

XINFERENCE_HOST="${XINFERENCE_HOST:-0.0.0.0}"
XINFERENCE_PORT="${XINFERENCE_PORT:-9997}"
XINFERENCE_ENDPOINT="${XINFERENCE_ENDPOINT:-http://127.0.0.1:${XINFERENCE_PORT}}"
DATA_DIR="${QWEN3_XINFERENCE_DATA_DIR:-${SCRIPT_DIR}/data/qwen3-xinference}"
XINFERENCE_HOME_DIR="${XINFERENCE_HOME:-${DATA_DIR}/home}"
CONDA_ENV_NAME="${QWEN3_XINFERENCE_CONDA_ENV_NAME:-xinference_python3.12}"
CONDA_ENV_DIR="${QWEN3_XINFERENCE_CONDA_ENV_DIR:-}"
CONDA_PYTHON_VERSION="${QWEN3_XINFERENCE_PYTHON_VERSION:-3.12}"
CONDA_EXE="${QWEN3_XINFERENCE_CONDA:-${DEFAULT_CONDA_EXE}}"
CONDA_CREATE_ARGS="${QWEN3_XINFERENCE_CONDA_CREATE_ARGS:---override-channels -c conda-forge}"
LOG_DIR="${QWEN3_XINFERENCE_LOG_DIR:-${DATA_DIR}/logs}"
PID_FILE="${QWEN3_XINFERENCE_PID_FILE:-${DATA_DIR}/xinference-local.pid}"
LOG_FILE="${QWEN3_XINFERENCE_LOG_FILE:-${LOG_DIR}/xinference-local.log}"
WATCHDOG_PID_FILE="${QWEN3_WATCHDOG_PID_FILE:-${DATA_DIR}/qwen3-watchdog.pid}"
WATCHDOG_LOG_FILE="${QWEN3_WATCHDOG_LOG_FILE:-${LOG_DIR}/qwen3-watchdog.log}"
NUMBA_CACHE_DIR="${NUMBA_CACHE_DIR:-${DATA_DIR}/numba-cache}"
WATCHDOG_INTERVAL="${QWEN3_WATCHDOG_INTERVAL:-60}"
WATCHDOG_ENABLED="${QWEN3_WATCHDOG_ENABLED:-true}"
WATCHDOG_RESTART_ON_START="${QWEN3_WATCHDOG_RESTART_ON_START:-true}"
START_TIMEOUT="${QWEN3_XINFERENCE_START_TIMEOUT:-300}"
PROBE_TIMEOUT="${QWEN3_XINFERENCE_PROBE_TIMEOUT:-120}"
XINFERENCE_PIP_SPEC="${QWEN3_XINFERENCE_PIP_SPEC:-xinference[audio]>=2.5.0}"
MLX_AUDIO_PIP_SPEC="${QWEN3_MLX_AUDIO_PIP_SPEC:-}"
QWEN_TTS_PIP_SPEC="${QWEN3_QWEN_TTS_PIP_SPEC:-qwen-tts}"
QWEN_TTS_RUNTIME_PIP_SPECS="${QWEN3_QWEN_TTS_RUNTIME_PIP_SPECS:-transformers==4.57.3 accelerate==1.12.0 huggingface-hub>=0.34.0,<1.0 librosa torchaudio soundfile sox onnxruntime einops}"
QWEN_TTS_INSTALL_NO_DEPS="${QWEN3_QWEN_TTS_INSTALL_NO_DEPS:-true}"
XINFERENCE_DISABLE_METRICS="${XINFERENCE_DISABLE_METRICS:-1}"
XINFERENCE_ENABLE_VIRTUAL_ENV="${XINFERENCE_ENABLE_VIRTUAL_ENV:-0}"
XINFERENCE_MODEL_SRC="${XINFERENCE_MODEL_SRC:-huggingface}"
XINFERENCE_AUTH_ADVANCED="${XINFERENCE_AUTH_ADVANCED:-false}"
REPLACE_STALE_SERVER="${QWEN3_XINFERENCE_REPLACE_STALE_SERVER:-true}"
RECREATE_MISMATCHED_CONTAINER="${QWEN3_XIAOZHI_RECREATE_MISMATCHED_CONTAINER:-true}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"

MODEL_NAME="${QWEN3_XINFERENCE_MODEL_NAME:-Qwen3-TTS-12Hz-0.6B-CustomVoice}"
MODEL_UID="${QWEN3_XINFERENCE_MODEL_UID:-Qwen3-TTS-12Hz-0.6B-CustomVoice}"
MODEL_ENGINE="${QWEN3_XINFERENCE_MODEL_ENGINE:-MLX}"
MODEL_DEVICE="${QWEN3_XINFERENCE_MODEL_DEVICE:-cpu}"
MODEL_URI="${QWEN3_XINFERENCE_MODEL_URI:-}"
DOWNLOAD_HUB="${QWEN3_XINFERENCE_DOWNLOAD_HUB:-huggingface}"
VOICE_RAW="${QWEN3_XINFERENCE_VOICE:-${XIAOZHI_TTS_VOICE:-serena}}"
VOICE_LOWER="$(printf '%s' "${VOICE_RAW}" | tr '[:upper:]' '[:lower:]')"
case "${VOICE_LOWER}" in
  aiden|dylan|eric|ono_anna|ryan|serena|sohee|uncle_fu|vivian)
    VOICE="${VOICE_LOWER}"
    ;;
  *)
    VOICE="${VOICE_RAW}"
    ;;
esac
LANGUAGE="${QWEN3_XINFERENCE_LANGUAGE:-chinese}"
INSTRUCT="${QWEN3_XINFERENCE_INSTRUCT:-}"
FORMAT="${QWEN3_XINFERENCE_FORMAT:-${XIAOZHI_TTS_FORMAT:-wav}}"
SPEED="${QWEN3_XINFERENCE_SPEED:-${XIAOZHI_TTS_SPEED:-1}}"
STREAM="${QWEN3_XINFERENCE_STREAM:-false}"
PROBE_AUDIO_AFTER_LAUNCH="${QWEN3_XINFERENCE_PROBE_AUDIO:-false}"

COMPOSE_FILE="${XIAOZHI_MLX_COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.local-qwen3-mlx.yml}"
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

start_detached_process() {
  local output_file="$1"
  shift

  mkdir -p "$(dirname "${output_file}")"
  DETACHED_OUTPUT_FILE="${output_file}" "$(find_python3)" - "$@" <<'PY'
import os
import subprocess
import sys

output_file = os.environ["DETACHED_OUTPUT_FILE"]
command = sys.argv[1:]
with open(output_file, "ab", buffering=0) as output:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=output,
        stderr=subprocess.STDOUT,
        close_fds=True,
        start_new_session=True,
        env=os.environ.copy(),
    )
print(process.pid)
PY
}

usage() {
  cat <<EOF
用法: $(basename "$0") [start|stop|restart|status|init|probe|logs|watchdog-logs]

命令:
  start    创建/检查 Conda 环境，启动 Xinference、Qwen3 模型和 xiaozhi 容器，然后启动后台守护
  stop     停止后台守护、xiaozhi 容器、Qwen3 模型和本脚本启动的 Xinference
  restart  先 stop 再 start
  status   查看 Xinference、模型和 xiaozhi 容器状态
  init     只创建 Conda 环境并安装依赖
  probe    调用 /v1/audio/speech 生成一段测试音频
  logs     跟随 Xinference 日志
  watchdog-logs 跟随后台守护日志

常用环境变量:
  QWEN3_XINFERENCE_CONDA_ENV_NAME=${CONDA_ENV_NAME}
  QWEN3_XINFERENCE_MODEL_NAME=${MODEL_NAME}
  QWEN3_XINFERENCE_MODEL_ENGINE=${MODEL_ENGINE}
  QWEN3_XINFERENCE_MODEL_DEVICE=${MODEL_DEVICE}
  QWEN3_XINFERENCE_VOICE=${VOICE}
  QWEN3_XINFERENCE_LANGUAGE=${LANGUAGE}
  QWEN3_XINFERENCE_REPLACE_STALE_SERVER=${REPLACE_STALE_SERVER}
  QWEN3_XIAOZHI_RECREATE_MISMATCHED_CONTAINER=${RECREATE_MISMATCHED_CONTAINER}
  QWEN3_QWEN_TTS_PIP_SPEC=${QWEN_TTS_PIP_SPEC}
  QWEN3_QWEN_TTS_RUNTIME_PIP_SPECS=${QWEN_TTS_RUNTIME_PIP_SPECS}
  QWEN3_QWEN_TTS_INSTALL_NO_DEPS=${QWEN_TTS_INSTALL_NO_DEPS}
  QWEN3_MLX_AUDIO_PIP_SPEC=${MLX_AUDIO_PIP_SPEC:-<不安装>}
  QWEN3_WATCHDOG_ENABLED=${WATCHDOG_ENABLED}
  QWEN3_WATCHDOG_INTERVAL=${WATCHDOG_INTERVAL}
  QWEN3_WATCHDOG_RESTART_ON_START=${WATCHDOG_RESTART_ON_START}
  NUMBA_CACHE_DIR=${NUMBA_CACHE_DIR}
  XINFERENCE_AUTH_ADVANCED=${XINFERENCE_AUTH_ADVANCED}
  XINFERENCE_PORT=${XINFERENCE_PORT}
EOF
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

make_tts_kwargs_json() {
  LANGUAGE="${LANGUAGE}" INSTRUCT="${INSTRUCT}" "$(find_python3)" - <<'PY'
import json
import os

payload = {"language": os.environ["LANGUAGE"]}
instruct = os.environ.get("INSTRUCT", "").strip()
if instruct:
    payload["instruct"] = instruct
print(json.dumps(payload, ensure_ascii=False))
PY
}

make_probe_body() {
  MODEL_UID="${MODEL_UID}" \
    VOICE="${VOICE}" \
    FORMAT="${FORMAT}" \
    SPEED="${SPEED}" \
    STREAM="${STREAM}" \
    TTS_KWARGS_JSON="${XIAOZHI_TTS_KWARGS_JSON:-$(make_tts_kwargs_json)}" \
    "$(find_python3)" - <<'PY'
import json
import os

kwargs = json.loads(os.environ["TTS_KWARGS_JSON"])
payload = {
    "model": os.environ["MODEL_UID"],
    "input": "你好，我是小智。",
    "voice": os.environ["VOICE"],
    "response_format": os.environ["FORMAT"],
    "speed": float(os.environ["SPEED"]),
    "stream": os.environ["STREAM"].lower() in ("1", "true", "yes", "on"),
    "kwargs": json.dumps(kwargs, ensure_ascii=False),
}
print(json.dumps(payload, ensure_ascii=False))
PY
}

server_http_code() {
  command_exists curl || die "未找到 curl，无法检测 Xinference 服务。"

  curl -sS \
    --max-time 5 \
    -o /dev/null \
    -w '%{http_code}' \
    "${XINFERENCE_ENDPOINT}/v1/models" \
    2>/dev/null || true
}

server_available() {
  [ "$(server_http_code)" = "200" ]
}

server_responds() {
  local http_code
  http_code="$(server_http_code)"
  [ -n "${http_code}" ] && [ "${http_code}" != "000" ]
}

model_is_running() {
  command_exists curl || return 1

  ENDPOINT="${XINFERENCE_ENDPOINT}" MODEL_UID="${MODEL_UID}" MODEL_NAME="${MODEL_NAME}" \
    "$(find_python3)" - <<'PY' >/dev/null 2>&1
import json
import os
import sys
import urllib.request

endpoint = os.environ["ENDPOINT"].rstrip("/")
model_uid = os.environ["MODEL_UID"]
model_name = os.environ["MODEL_NAME"]
targets = {model_uid}
if model_uid == model_name:
    targets.add(model_name)

try:
    with urllib.request.urlopen(endpoint + "/v1/models", timeout=5) as response:
        data = json.loads(response.read().decode("utf-8"))
except Exception:
    sys.exit(1)

def contains_target(value):
    if isinstance(value, dict):
        if targets.intersection(value.keys()):
            return True
        for key in ("model_uid", "uid", "id"):
            if value.get(key) in targets:
                return True
        return any(contains_target(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_target(item) for item in value)
    if isinstance(value, str):
        return value in targets
    return False

sys.exit(0 if contains_target(data) else 1)
PY
}

probe_model_audio() {
  command_exists curl || die "未找到 curl，无法检测 Qwen3 Xinference 模型。"

  local tmp_base tmp_file http_code
  tmp_base="$(mktemp "${TMPDIR:-/tmp}/qwen3-xinference-probe.XXXXXX")"
  tmp_file="${tmp_base}.${FORMAT}"
  mv "${tmp_base}" "${tmp_file}"
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
    info "测试音频已生成：${tmp_file}"
    return 0
  fi

  local response_preview
  response_preview="$(head -c 500 "${tmp_file}" 2>/dev/null | tr '\n' ' ' || true)"
  warn "Qwen3 TTS 音频探测失败：HTTP=${http_code:-unknown}，响应=${response_preview:-<empty>}"
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

watchdog_is_alive() {
  [ -f "${WATCHDOG_PID_FILE}" ] || return 1
  local pid
  pid="$(cat "${WATCHDOG_PID_FILE}" 2>/dev/null || true)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" >/dev/null 2>&1
  if command_exists ps; then
    ps -p "${pid}" -o command= 2>/dev/null | grep -q "start-qwen3-mlx.sh watchdog"
    return
  fi
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

xinference_listener_pids() {
  command_exists lsof || return 0
  lsof -nP -tiTCP:"${XINFERENCE_PORT}" -sTCP:LISTEN 2>/dev/null || true
}

server_uses_expected_env() {
  command_exists ps || return 0

  local expected_prefix pid command_line found_xinference
  expected_prefix="$(conda_env_prefix 2>/dev/null || true)"
  [ -n "${expected_prefix}" ] || return 0

  found_xinference=false
  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command_line}" in
      *xinference-local*)
        found_xinference=true
        case "${command_line}" in
          *"${expected_prefix}/bin/python"*|*"${expected_prefix}/bin/xinference-local"*)
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$(xinference_listener_pids)
EOF

  if [ "${found_xinference}" = "true" ]; then
    return 1
  fi
  return 0
}

current_xinference_command() {
  command_exists ps || return 0

  local pid command_line
  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command_line}" in
      *xinference-local*)
        printf '%s\n' "${command_line}"
        ;;
    esac
  done <<EOF
$(xinference_listener_pids)
EOF
}

ensure_conda_env() {
  mkdir -p "${DATA_DIR}" "${LOG_DIR}" "${XINFERENCE_HOME_DIR}" "${NUMBA_CACHE_DIR}"
  if [ -n "$(env_python_if_exists || true)" ]; then
    info "使用 Conda 环境：$(conda_env_prefix)"
    return
  fi

  [ -n "${CONDA_EXE}" ] || die "未找到 conda，请先安装 Conda 或设置 QWEN3_XINFERENCE_CONDA。"
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
  MIN_XINFERENCE_VERSION="${QWEN3_MIN_XINFERENCE_VERSION:-2.5.0}" \
    NUMBA_CACHE_DIR="${NUMBA_CACHE_DIR}" \
    "$(env_python)" - <<'PY' >/dev/null 2>&1
import importlib.util
import os
import re
import sys
from importlib.metadata import PackageNotFoundError, version

required = [
    "xinference",
    "qwen_tts",
    "soundfile",
]
missing = []
for name in required:
    if importlib.util.find_spec(name) is None:
        missing.append(name)
        continue
    try:
        __import__(name)
    except Exception:
        missing.append(name)
if missing:
    sys.exit(1)

def version_tuple(value):
    parts = re.findall(r"\d+", value)
    return tuple(int(part) for part in parts[:3])

try:
    installed = version("xinference")
except PackageNotFoundError:
    sys.exit(1)

if version_tuple(installed) < version_tuple(os.environ["MIN_XINFERENCE_VERSION"]):
    sys.exit(1)
PY
}

ensure_deps() {
  if deps_ready && [ -x "$(env_bin xinference-local)" ]; then
    return
  fi

  info "安装 Xinference + Qwen3 MLX 依赖。首次安装会比较久。"
  "$(env_python)" -m pip install -U pip
  local base_packages=(
    "${XINFERENCE_PIP_SPEC}"
    soundfile
  )
  "$(env_python)" -m pip install -U "${base_packages[@]}"

  local runtime_packages=()
  # shellcheck disable=SC2206
  runtime_packages=(${QWEN_TTS_RUNTIME_PIP_SPECS})
  if [ "${#runtime_packages[@]}" -gt 0 ]; then
    "$(env_python)" -m pip install -U "${runtime_packages[@]}"
  fi

  if [ "${QWEN_TTS_INSTALL_NO_DEPS}" = "true" ]; then
    "$(env_python)" -m pip install -U --no-deps "${QWEN_TTS_PIP_SPEC}"
  else
    "$(env_python)" -m pip install -U "${QWEN_TTS_PIP_SPEC}"
  fi

  if [ -n "${MLX_AUDIO_PIP_SPEC}" ]; then
    "$(env_python)" -m pip install -U "${MLX_AUDIO_PIP_SPEC}"
  fi
}

wait_for_server() {
  local start_ts now http_code
  start_ts="$(date +%s)"
  while true; do
    http_code="$(server_http_code)"
    if [ "${http_code}" = "200" ]; then
      return
    fi
    if [ "${http_code}" = "401" ]; then
      die "Xinference 已响应但返回 401。请确认 XINFERENCE_AUTH_ADVANCED=false 已生效，或先执行 stop 后重新 start。"
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
    if server_uses_expected_env; then
      info "Xinference 服务已可用：${XINFERENCE_ENDPOINT}"
      return
    fi

    warn "端口 ${XINFERENCE_PORT} 上已有其他 Xinference 进程，不是当前 Conda 环境：$(conda_env_prefix)"
    current_xinference_command | while IFS= read -r command_line; do
      warn "当前进程：${command_line}"
    done

    if [ "${REPLACE_STALE_SERVER}" = "true" ]; then
      warn "按 QWEN3_XINFERENCE_REPLACE_STALE_SERVER=true 停止旧 Xinference 并重启。"
      stop_xinference_server
    else
      die "请先停止旧 Xinference，或设置 QWEN3_XINFERENCE_REPLACE_STALE_SERVER=true。"
    fi
  fi

  if port_is_listening; then
    local http_code xinference_command
    http_code="$(server_http_code)"
    xinference_command="$(current_xinference_command || true)"
    if [ -n "${xinference_command}" ]; then
      warn "端口 ${XINFERENCE_PORT} 上已有 Xinference 进程，但 /v1/models 未返回 200，当前 HTTP 状态码：${http_code:-unknown}"
      printf '%s\n' "${xinference_command}" | while IFS= read -r command_line; do
        warn "当前进程：${command_line}"
      done

      if [ "${REPLACE_STALE_SERVER}" = "true" ]; then
        warn "按 QWEN3_XINFERENCE_REPLACE_STALE_SERVER=true 停止当前 Xinference 并重启。"
        stop_xinference_server
      else
        die "请先停止当前 Xinference，或设置 QWEN3_XINFERENCE_REPLACE_STALE_SERVER=true。"
      fi
    else
      die "端口 ${XINFERENCE_PORT} 已被占用，但 ${XINFERENCE_ENDPOINT} 不可用。请检查占用进程。"
    fi
  fi

  if port_is_listening; then
    die "端口 ${XINFERENCE_PORT} 仍被占用，无法启动 Xinference。"
  fi

  info "启动 Xinference 服务：${XINFERENCE_ENDPOINT}"
  export XINFERENCE_HOME="${XINFERENCE_HOME_DIR}"
  export XINFERENCE_DISABLE_METRICS="${XINFERENCE_DISABLE_METRICS}"
  export XINFERENCE_ENABLE_VIRTUAL_ENV="${XINFERENCE_ENABLE_VIRTUAL_ENV}"
  export XINFERENCE_MODEL_SRC="${XINFERENCE_MODEL_SRC}"
  export XINFERENCE_AUTH_ADVANCED="${XINFERENCE_AUTH_ADVANCED}"
  export NUMBA_CACHE_DIR="${NUMBA_CACHE_DIR}"
  export HF_ENDPOINT="${HF_ENDPOINT}"
  export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET}"
  start_detached_process \
    "${LOG_FILE}" \
    "$(env_bin xinference-local)" \
    --host "${XINFERENCE_HOST}" \
    --port "${XINFERENCE_PORT}" \
    >"${PID_FILE}"
  wait_for_server
}

launch_model() {
  if model_is_running; then
    info "Xinference 中的 ${MODEL_UID} 已运行，跳过模型启动。"
    return
  fi

  info "启动 Xinference 模型：name=${MODEL_NAME}, uid=${MODEL_UID}, engine=${MODEL_ENGINE}"
  ENDPOINT="${XINFERENCE_ENDPOINT}" \
    MODEL_NAME="${MODEL_NAME}" \
    MODEL_UID="${MODEL_UID}" \
    MODEL_ENGINE="${MODEL_ENGINE}" \
    MODEL_DEVICE="${MODEL_DEVICE}" \
    DOWNLOAD_HUB="${DOWNLOAD_HUB}" \
    MODEL_URI="${MODEL_URI}" \
    NUMBA_CACHE_DIR="${NUMBA_CACHE_DIR}" \
    "$(env_python)" - <<'PY'
import os
import sys

from xinference.client import Client

client = Client(os.environ["ENDPOINT"])
kwargs = {
    "model_name": os.environ["MODEL_NAME"],
    "model_type": "audio",
    "model_uid": os.environ["MODEL_UID"],
    "model_engine": os.environ["MODEL_ENGINE"],
    "download_hub": os.environ.get("DOWNLOAD_HUB") or "huggingface",
    "enable_virtual_env": False,
}
model_device = os.environ.get("MODEL_DEVICE")
if model_device:
    kwargs["device"] = model_device
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
    if model_is_running; then
      info "Xinference 模型 ${MODEL_UID} 已进入运行列表。"
      break
    fi

    now="$(date +%s)"
    if [ $((now - start_ts)) -ge "${START_TIMEOUT}" ]; then
      die "等待 Xinference 模型 ${MODEL_UID} 进入运行列表超时，请查看日志：${LOG_FILE}"
    fi

    sleep 3
  done

  if [ "${PROBE_AUDIO_AFTER_LAUNCH}" = "true" ]; then
    info "按 QWEN3_XINFERENCE_PROBE_AUDIO=true 执行音频探测。"
    probe_model_audio || die "Qwen3 TTS 音频探测失败，请查看日志：${LOG_FILE}"
  fi
}

start_inference() {
  ensure_conda_env
  ensure_deps

  if server_available && model_is_running && server_uses_expected_env; then
    info "Xinference + ${MODEL_UID} 已可用，跳过 inference 启动。"
    return
  fi

  start_xinference_server
  launch_model
}

container_is_running() {
  command_exists docker || return 1
  docker ps \
    --filter "name=^/${CONTAINER_NAME}$" \
    --filter "status=running" \
    --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER_NAME}"
}

container_env_value() {
  local key="$1"
  docker inspect "${CONTAINER_NAME}" \
    --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | awk -F= -v key="${key}" '$1 == key { print substr($0, length(key) + 2); exit }'
}

container_matches_expected_tts_env() {
  [ "$(container_env_value XIAOZHI_TTS_MODE)" = "${XIAOZHI_TTS_MODE}" ] || return 1
  [ "$(container_env_value XIAOZHI_TTS_PROVIDER)" = "${XIAOZHI_TTS_PROVIDER}" ] || return 1
  [ "$(container_env_value XIAOZHI_TTS_URL)" = "${XIAOZHI_TTS_URL}" ] || return 1
  [ "$(container_env_value XIAOZHI_TTS_MODEL)" = "${XIAOZHI_TTS_MODEL}" ] || return 1
  [ "$(container_env_value XIAOZHI_TTS_VOICE)" = "${XIAOZHI_TTS_VOICE}" ] || return 1
  [ "$(container_env_value XIAOZHI_TTS_LANGUAGE)" = "${XIAOZHI_TTS_LANGUAGE}" ] || return 1
}

start_xiaozhi_server() {
  command_exists docker || die "未找到 docker。"

  [ -f "${COMPOSE_FILE}" ] || die "未找到 Compose 文件：${COMPOSE_FILE}"

  export XIAOZHI_TTS_MODE="${XIAOZHI_TTS_MODE:-local}"
  export XIAOZHI_TTS_PROVIDER="${XIAOZHI_TTS_PROVIDER:-CustomTTS}"
  export XIAOZHI_TTS_URL="${XIAOZHI_TTS_URL:-${CONTAINER_TTS_URL}}"
  export XIAOZHI_TTS_MODEL="${XIAOZHI_TTS_MODEL:-${MODEL_UID}}"
  export XIAOZHI_TTS_VOICE="${XIAOZHI_TTS_VOICE:-${VOICE}}"
  export XIAOZHI_TTS_FORMAT="${XIAOZHI_TTS_FORMAT:-${FORMAT}}"
  export XIAOZHI_TTS_SPEED="${XIAOZHI_TTS_SPEED:-${SPEED}}"
  export XIAOZHI_TTS_STREAM="${XIAOZHI_TTS_STREAM:-${STREAM}}"
  export XIAOZHI_TTS_LANGUAGE="${XIAOZHI_TTS_LANGUAGE:-${LANGUAGE}}"
  export XIAOZHI_TTS_INSTRUCT="${XIAOZHI_TTS_INSTRUCT:-${INSTRUCT}}"

  if container_is_running; then
    if container_matches_expected_tts_env; then
      info "Docker 容器 ${CONTAINER_NAME} 已按 Qwen3 TTS 配置运行，跳过启动。"
      return
    fi

    warn "Docker 容器 ${CONTAINER_NAME} 已运行，但 TTS 环境不是当前 Qwen3 配置。"
    warn "当前模型：$(container_env_value XIAOZHI_TTS_MODEL)，当前音色：$(container_env_value XIAOZHI_TTS_VOICE)"
    if [ "${RECREATE_MISMATCHED_CONTAINER}" != "true" ]; then
      die "请先停止旧容器，或设置 QWEN3_XIAOZHI_RECREATE_MISMATCHED_CONTAINER=true。"
    fi
    warn "按 QWEN3_XIAOZHI_RECREATE_MISMATCHED_CONTAINER=true 重建容器。"
  fi

  info "启动 Docker 版 ${CONTAINER_NAME}。"
  local compose_cmd
  compose_cmd="$(docker_compose_cmd)"
  # shellcheck disable=SC2086
  ${compose_cmd} -f "${COMPOSE_FILE}" up -d --build --force-recreate xiaozhi-esp32-server
}

stop_xiaozhi_server() {
  if ! command_exists docker; then
    warn "未找到 docker，跳过 Docker 容器停止。"
    return
  fi

  if container_is_running; then
    info "停止 Docker 容器 ${CONTAINER_NAME}。"
    docker stop "${CONTAINER_NAME}" >/dev/null
  else
    info "Docker 容器 ${CONTAINER_NAME} 未运行。"
  fi
}

terminate_qwen3_model() {
  if ! server_available; then
    info "Xinference 服务不可用，跳过模型终止。"
    return
  fi

  if ! model_is_running; then
    info "Xinference 模型 ${MODEL_UID} 未运行。"
    return
  fi

  info "终止 Xinference 模型 ${MODEL_UID}。"
  if [ -n "$(env_python_if_exists || true)" ]; then
    ENDPOINT="${XINFERENCE_ENDPOINT}" MODEL_UID="${MODEL_UID}" "$(env_python)" - <<'PY' || true
import os

from xinference.client import Client

try:
    Client(os.environ["ENDPOINT"]).terminate_model(model_uid=os.environ["MODEL_UID"])
except Exception as exc:
    print(f"terminate_model failed: {exc}")
PY
  else
    curl -sS \
      --max-time 10 \
      -X DELETE "${XINFERENCE_ENDPOINT}/v1/models/${MODEL_UID}" \
      >/dev/null 2>&1 || true
  fi
}

stop_pid_process() {
  local pid="$1"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1

  info "停止 Xinference 服务进程 pid=${pid}。"
  kill "${pid}" >/dev/null 2>&1 || true

  local i
  for i in {1..15}; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  warn "Xinference 服务进程 pid=${pid} 未正常退出，强制停止。"
  kill -KILL "${pid}" >/dev/null 2>&1 || true
}

stop_listening_xinference_processes() {
  command_exists lsof || return 0

  local pid command_line
  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command_line}" in
      *xinference-local*--port*"${XINFERENCE_PORT}"*|*xinference-local*"-p ${XINFERENCE_PORT}"*)
        stop_pid_process "${pid}" || true
        ;;
    esac
  done <<EOF
$(lsof -nP -tiTCP:"${XINFERENCE_PORT}" -sTCP:LISTEN 2>/dev/null || true)
EOF
}

stop_xinference_server() {
  terminate_qwen3_model

  if pid_is_alive; then
    stop_pid_process "$(cat "${PID_FILE}")" || true
    rm -f "${PID_FILE}"
    return
  fi

  rm -f "${PID_FILE}"
  if port_is_listening; then
    stop_listening_xinference_processes
    if port_is_listening; then
      warn "端口 ${XINFERENCE_PORT} 仍在监听；未发现由 xinference-local 启动且匹配端口的进程。"
    fi
  else
    info "Xinference 服务未运行。"
  fi
}

start_watchdog() {
  if [ "${WATCHDOG_ENABLED}" != "true" ]; then
    info "后台守护未启用：QWEN3_WATCHDOG_ENABLED=${WATCHDOG_ENABLED}"
    return
  fi

  mkdir -p "${DATA_DIR}" "${LOG_DIR}"
  if watchdog_is_alive; then
    info "后台守护已运行，pid=$(cat "${WATCHDOG_PID_FILE}")"
    return
  fi

  rm -f "${WATCHDOG_PID_FILE}"
  info "启动后台守护，interval=${WATCHDOG_INTERVAL}s，日志：${WATCHDOG_LOG_FILE}"
  start_detached_process "${WATCHDOG_LOG_FILE}" "${SCRIPT_PATH}" watchdog >"${WATCHDOG_PID_FILE}"
}

refresh_watchdog_for_start() {
  if [ "${WATCHDOG_ENABLED}" != "true" ]; then
    return
  fi
  if [ "${WATCHDOG_RESTART_ON_START}" != "true" ]; then
    return
  fi
  if watchdog_is_alive; then
    info "重启后台守护以加载当前脚本配置。"
    stop_watchdog
  fi
}

stop_watchdog() {
  if ! watchdog_is_alive; then
    rm -f "${WATCHDOG_PID_FILE}"
    info "后台守护未运行。"
    return
  fi

  local pid
  pid="$(cat "${WATCHDOG_PID_FILE}" 2>/dev/null || true)"
  info "停止后台守护 pid=${pid}。"
  kill "${pid}" >/dev/null 2>&1 || true

  local i
  for i in {1..10}; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      rm -f "${WATCHDOG_PID_FILE}"
      return
    fi
    sleep 1
  done

  warn "后台守护 pid=${pid} 未正常退出，强制停止。"
  kill -KILL "${pid}" >/dev/null 2>&1 || true
  rm -f "${WATCHDOG_PID_FILE}"
}

run_watchdog() {
  mkdir -p "${DATA_DIR}" "${LOG_DIR}"
  echo "$$" >"${WATCHDOG_PID_FILE}"
  trap 'rm -f "${WATCHDOG_PID_FILE}"; exit 0' INT TERM EXIT

  info "后台守护已启动，pid=$$，interval=${WATCHDOG_INTERVAL}s。"
  while true; do
    if ! server_available || ! server_uses_expected_env || ! model_is_running; then
      warn "后台守护检测到 Xinference/Qwen3 状态不完整，尝试恢复。"
      (start_inference) || warn "后台守护恢复 Xinference/Qwen3 失败。"
    fi

    export XIAOZHI_TTS_MODE="${XIAOZHI_TTS_MODE:-local}"
    export XIAOZHI_TTS_PROVIDER="${XIAOZHI_TTS_PROVIDER:-CustomTTS}"
    export XIAOZHI_TTS_URL="${XIAOZHI_TTS_URL:-${CONTAINER_TTS_URL}}"
    export XIAOZHI_TTS_MODEL="${XIAOZHI_TTS_MODEL:-${MODEL_UID}}"
    export XIAOZHI_TTS_VOICE="${XIAOZHI_TTS_VOICE:-${VOICE}}"
    export XIAOZHI_TTS_FORMAT="${XIAOZHI_TTS_FORMAT:-${FORMAT}}"
    export XIAOZHI_TTS_SPEED="${XIAOZHI_TTS_SPEED:-${SPEED}}"
    export XIAOZHI_TTS_STREAM="${XIAOZHI_TTS_STREAM:-${STREAM}}"
    export XIAOZHI_TTS_LANGUAGE="${XIAOZHI_TTS_LANGUAGE:-${LANGUAGE}}"
    export XIAOZHI_TTS_INSTRUCT="${XIAOZHI_TTS_INSTRUCT:-${INSTRUCT}}"

    if ! container_is_running || ! container_matches_expected_tts_env; then
      warn "后台守护检测到 xiaozhi 容器未运行或 TTS 配置不匹配，尝试恢复。"
      (start_xiaozhi_server) || warn "后台守护恢复 xiaozhi 容器失败。"
    fi

    sleep "${WATCHDOG_INTERVAL}"
  done
}

show_status() {
  local http_code
  http_code="$(server_http_code)"
  info "工作目录：${REPO_ROOT}"
  info "Conda 环境：${CONDA_ENV_NAME}"
  if [ "${http_code}" = "200" ]; then
    info "Xinference 服务：运行中 ${XINFERENCE_ENDPOINT}"
    if ! server_uses_expected_env; then
      warn "当前 Xinference 不是 ${CONDA_ENV_NAME} 环境启动的，start 会自动替换旧服务。"
      current_xinference_command | while IFS= read -r command_line; do
        warn "当前进程：${command_line}"
      done
    fi
  elif [ -n "${http_code}" ] && [ "${http_code}" != "000" ]; then
    warn "Xinference 服务：有响应但不可用 ${XINFERENCE_ENDPOINT}，/v1/models HTTP=${http_code}"
  else
    info "Xinference 服务：未运行"
  fi

  if model_is_running; then
    info "Qwen3 模型：运行中 ${MODEL_UID}"
  else
    info "Qwen3 模型：未运行 ${MODEL_UID}"
  fi

  if container_is_running; then
    info "Docker 容器：运行中 ${CONTAINER_NAME}"
  else
    info "Docker 容器：未运行 ${CONTAINER_NAME}"
  fi
  if watchdog_is_alive; then
    info "后台守护：运行中 pid=$(cat "${WATCHDOG_PID_FILE}")"
  else
    info "后台守护：未运行"
  fi
  info "Xinference 日志：${LOG_FILE}"
  info "后台守护日志：${WATCHDOG_LOG_FILE}"
}

start_all() {
  info "工作目录：${REPO_ROOT}"
  refresh_watchdog_for_start
  start_inference
  start_xiaozhi_server
  start_watchdog
  info "启动流程完成。"
  info "Xinference endpoint：${XINFERENCE_ENDPOINT}"
  info "TTS endpoint for Docker：${CONTAINER_TTS_URL}"
  info "Model UID：${MODEL_UID}"
  info "Xinference 日志：${LOG_FILE}"
  info "后台守护日志：${WATCHDOG_LOG_FILE}"
}

stop_all() {
  stop_watchdog
  stop_xiaozhi_server
  stop_xinference_server
  info "停止流程完成。"
}

main() {
  local command="${1:-start}"
  case "${command}" in
    start)
      start_all
      ;;
    stop)
      stop_all
      ;;
    restart)
      stop_all
      start_all
      ;;
    status)
      show_status
      ;;
    init)
      ensure_conda_env
      ensure_deps
      ;;
    probe)
      probe_model_audio
      ;;
    logs)
      mkdir -p "${LOG_DIR}"
      touch "${LOG_FILE}"
      tail -f "${LOG_FILE}"
      ;;
    watchdog-logs)
      mkdir -p "${LOG_DIR}"
      touch "${WATCHDOG_LOG_FILE}"
      tail -f "${WATCHDOG_LOG_FILE}"
      ;;
    watchdog)
      run_watchdog
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      usage
      die "未知命令：${command}"
      ;;
  esac
}

main "$@"
