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

F5_MLX_HOST="${F5_MLX_HOST:-0.0.0.0}"
F5_MLX_PORT="${F5_MLX_PORT:-8002}"
F5_MLX_ENDPOINT="${F5_MLX_ENDPOINT:-http://127.0.0.1:${F5_MLX_PORT}}"
DATA_DIR="${F5_MLX_DATA_DIR:-${SCRIPT_DIR}/data/f5-mlx}"
LOG_DIR="${F5_MLX_LOG_DIR:-${DATA_DIR}/logs}"
PID_FILE="${F5_MLX_PID_FILE:-${DATA_DIR}/f5-mlx-server.pid}"
LOG_FILE="${F5_MLX_LOG_FILE:-${LOG_DIR}/f5-mlx-server.log}"
WATCHDOG_PID_FILE="${F5_MLX_WATCHDOG_PID_FILE:-${DATA_DIR}/f5-mlx-watchdog.pid}"
WATCHDOG_LOG_FILE="${F5_MLX_WATCHDOG_LOG_FILE:-${LOG_DIR}/f5-mlx-watchdog.log}"
VOICE_DIR="${F5_MLX_VOICE_DIR:-${DATA_DIR}/voices}"
HF_HOME_DIR="${F5_MLX_HF_HOME:-${DATA_DIR}/hf_cache}"
DEFAULT_REF_AUDIO="${F5_MLX_DEFAULT_ASSET_REF_AUDIO:-${SCRIPT_DIR}/config/assets/wakeup_words.wav}"
DEFAULT_REF_TEXT="${F5_MLX_DEFAULT_ASSET_REF_TEXT:-哈啰啊，我是小智啦，声音好听的台湾女孩一枚，超开心认识你耶，最近在忙啥，别忘了给我来点有趣的料哦，我超爱听八卦的啦}"
XIAOZHI_CONFIG_TTS_PROVIDER="${F5_MLX_XIAOZHI_CONFIG_TTS_PROVIDER:-EdgeTTS}"
XIAOZHI_CONFIG_VOICE="${F5_MLX_XIAOZHI_CONFIG_VOICE:-zh-CN-XiaoxiaoNeural}"
CONDA_ENV_NAME="${F5_MLX_CONDA_ENV_NAME:-f5_tts_mlx}"
CONDA_ENV_DIR="${F5_MLX_CONDA_ENV_DIR:-}"
CONDA_PYTHON_VERSION="${F5_MLX_PYTHON_VERSION:-3.11}"
CONDA_EXE="${F5_MLX_CONDA:-${DEFAULT_CONDA_EXE}}"
CONDA_CREATE_ARGS="${F5_MLX_CONDA_CREATE_ARGS:---override-channels -c conda-forge}"
F5_MLX_PIP_SPECS="${F5_MLX_PIP_SPECS:-f5-tts-mlx fastapi uvicorn[standard] pydantic}"
WATCHDOG_INTERVAL="${F5_MLX_WATCHDOG_INTERVAL:-60}"
WATCHDOG_ENABLED="${F5_MLX_WATCHDOG_ENABLED:-true}"
WATCHDOG_RESTART_ON_START="${F5_MLX_WATCHDOG_RESTART_ON_START:-true}"
STOP_COMPETING_WATCHDOGS="${F5_MLX_STOP_COMPETING_WATCHDOGS:-true}"
REPLACE_STALE_SERVER="${F5_MLX_REPLACE_STALE_SERVER:-true}"
RECREATE_MISMATCHED_CONTAINER="${F5_MLX_RECREATE_MISMATCHED_CONTAINER:-true}"
START_TIMEOUT="${F5_MLX_START_TIMEOUT:-300}"
PROBE_TIMEOUT="${F5_MLX_PROBE_TIMEOUT:-180}"
PRELOAD_MODEL="${F5_MLX_PRELOAD_MODEL:-true}"
REQUIRE_REFERENCE="${F5_MLX_REQUIRE_REFERENCE:-true}"
HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"

MODEL_NAME="${F5_MLX_MODEL_NAME:-lucasnewman/f5-tts-mlx}"
QUANTIZATION_BITS="${F5_MLX_QUANTIZATION_BITS:-4}"
VOICE="${F5_MLX_VOICE:-voice_01}"
REF_AUDIO="${F5_MLX_REF_AUDIO:-${VOICE_DIR}/${VOICE}.wav}"
REF_TEXT="${F5_MLX_REF_TEXT:-}"
REF_TEXT_FILE="${F5_MLX_REF_TEXT_FILE:-${VOICE_DIR}/${VOICE}.txt}"
LANG_CODE="${F5_MLX_LANG_CODE:-zh}"
FORMAT="${F5_MLX_FORMAT:-wav}"
SPEED="${F5_MLX_SPEED:-1}"
STREAM="${F5_MLX_STREAM:-false}"
ESTIMATE_DURATION="${F5_MLX_ESTIMATE_DURATION:-true}"
STEPS="${F5_MLX_STEPS:-8}"
METHOD="${F5_MLX_METHOD:-rk4}"
CFG="${F5_MLX_CFG:-2}"
SWAY_COEF="${F5_MLX_SWAY_COEF:--1}"
SERVER_FILE="${F5_MLX_SERVER_FILE:-${SCRIPT_DIR}/f5_mlx_openai_server.py}"

COMPOSE_FILE="${XIAOZHI_MLX_COMPOSE_FILE:-${SCRIPT_DIR}/docker-compose.local-f5-mlx.yml}"
CONTAINER_NAME="${XIAOZHI_SERVER_CONTAINER:-xiaozhi-esp32-server}"
HOST_TTS_URL="${F5_MLX_ENDPOINT}/v1/audio/speech"
CONTAINER_TTS_URL="${F5_MLX_DOCKER_TTS_URL:-http://host.docker.internal:${F5_MLX_PORT}/v1/audio/speech}"

if [ -z "${F5_MLX_REF_AUDIO:-}" ] && [ ! -f "${REF_AUDIO}" ] && [ -f "${DEFAULT_REF_AUDIO}" ]; then
  REF_AUDIO="${DEFAULT_REF_AUDIO}"
fi

if [ -z "${F5_MLX_REF_TEXT:-}" ] && [ ! -s "${REF_TEXT_FILE}" ] && [ "${REF_AUDIO}" = "${DEFAULT_REF_AUDIO}" ]; then
  REF_TEXT="${DEFAULT_REF_TEXT}"
fi

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
用法: $(basename "$0") [start|stop|restart|status|init|probe|prepare-voice|logs|watchdog-logs]

命令:
  start         创建/检查 Conda 环境，启动 F5-TTS MLX 服务、预加载模型和 xiaozhi 容器，然后启动后台守护
  stop          停止后台守护、xiaozhi 容器和本脚本启动的 F5-TTS MLX 服务
  restart       先 stop 再 start
  status        查看 F5-TTS MLX 服务、模型、参考音频和 xiaozhi 容器状态
  init          只创建 Conda 环境并安装依赖
  probe         调用 /v1/audio/speech 生成一段测试音频
  prepare-voice 把参考音频转换为 24kHz mono wav 并写入文字稿：prepare-voice INPUT_AUDIO REF_TEXT [VOICE]
  logs          跟随 F5-TTS MLX 服务日志
  watchdog-logs 跟随后台守护日志

常用环境变量:
  F5_MLX_CONDA_ENV_NAME=${CONDA_ENV_NAME}
  F5_MLX_PYTHON_VERSION=${CONDA_PYTHON_VERSION}
  F5_MLX_MODEL_NAME=${MODEL_NAME}
  F5_MLX_QUANTIZATION_BITS=${QUANTIZATION_BITS}
  F5_MLX_VOICE=${VOICE}
  F5_MLX_XIAOZHI_CONFIG_VOICE=${XIAOZHI_CONFIG_VOICE}
  F5_MLX_REF_AUDIO=${REF_AUDIO}
  F5_MLX_REF_TEXT=${REF_TEXT:-<从 ${REF_TEXT_FILE} 读取>}
  F5_MLX_REF_TEXT_FILE=${REF_TEXT_FILE}
  F5_MLX_VOICE_DIR=${VOICE_DIR}
  F5_MLX_PORT=${F5_MLX_PORT}
  F5_MLX_REQUIRE_REFERENCE=${REQUIRE_REFERENCE}
  F5_MLX_ESTIMATE_DURATION=${ESTIMATE_DURATION}
  F5_MLX_PRELOAD_MODEL=${PRELOAD_MODEL}
  F5_MLX_WATCHDOG_ENABLED=${WATCHDOG_ENABLED}
  F5_MLX_STOP_COMPETING_WATCHDOGS=${STOP_COMPETING_WATCHDOGS}
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

url_encode() {
  RAW_VALUE="$1" "$(find_python3)" - <<'PY'
import os
import urllib.parse

print(urllib.parse.quote(os.environ["RAW_VALUE"], safe=""))
PY
}

model_query_string() {
  local query
  query="model_name=$(url_encode "${MODEL_NAME}")"
  if [ -n "${QUANTIZATION_BITS}" ]; then
    query="${query}&q=$(url_encode "${QUANTIZATION_BITS}")"
  fi
  printf '%s\n' "${query}"
}

make_probe_body() {
  MODEL_NAME="${MODEL_NAME}" \
    VOICE="${VOICE}" \
    REF_AUDIO="${REF_AUDIO}" \
    REF_TEXT="${REF_TEXT}" \
    REF_TEXT_FILE="${REF_TEXT_FILE}" \
    FORMAT="${FORMAT}" \
    SPEED="${SPEED}" \
    STREAM="${STREAM}" \
    ESTIMATE_DURATION="${ESTIMATE_DURATION}" \
    LANG_CODE="${LANG_CODE}" \
    STEPS="${STEPS}" \
    METHOD="${METHOD}" \
    CFG="${CFG}" \
    SWAY_COEF="${SWAY_COEF}" \
    QUANTIZATION_BITS="${QUANTIZATION_BITS}" \
    "$(find_python3)" - <<'PY'
import json
import os

ref_text = os.environ.get("REF_TEXT", "").strip()
if not ref_text:
    ref_text_file = os.environ.get("REF_TEXT_FILE", "")
    if ref_text_file and os.path.isfile(ref_text_file):
        with open(ref_text_file, "r", encoding="utf-8") as handle:
            ref_text = handle.read().strip()

payload = {
    "model": os.environ["MODEL_NAME"],
    "input": "小智，给我讲个故事。",
    "voice": os.environ["VOICE"],
    "ref_audio": os.environ["REF_AUDIO"],
    "ref_text": ref_text,
    "response_format": os.environ["FORMAT"],
    "speed": float(os.environ["SPEED"]),
    "stream": os.environ["STREAM"].lower() in ("1", "true", "yes", "on"),
    "estimate_duration": os.environ["ESTIMATE_DURATION"].lower() in ("1", "true", "yes", "on"),
    "lang_code": os.environ["LANG_CODE"],
    "steps": int(os.environ["STEPS"]),
    "method": os.environ["METHOD"],
    "cfg": float(os.environ["CFG"]),
    "sway_coef": float(os.environ["SWAY_COEF"]),
}
if os.environ.get("QUANTIZATION_BITS"):
    payload["q"] = int(os.environ["QUANTIZATION_BITS"])
print(json.dumps(payload, ensure_ascii=False))
PY
}

server_http_code() {
  command_exists curl || die "未找到 curl，无法检测 F5-TTS MLX 服务。"

  curl -sS \
    --max-time 5 \
    -o /dev/null \
    -w '%{http_code}' \
    "${F5_MLX_ENDPOINT}/health" \
    2>/dev/null || true
}

server_available() {
  [ "$(server_http_code)" = "200" ]
}

model_is_running() {
  command_exists curl || return 1

  ENDPOINT="${F5_MLX_ENDPOINT}" MODEL_NAME="${MODEL_NAME}" \
    "$(find_python3)" - <<'PY' >/dev/null 2>&1
import json
import os
import sys
import urllib.request

endpoint = os.environ["ENDPOINT"].rstrip("/")
target = os.environ["MODEL_NAME"]

try:
    with urllib.request.urlopen(endpoint + "/v1/models", timeout=5) as response:
        data = json.loads(response.read().decode("utf-8"))
except Exception:
    sys.exit(1)

def contains_target(value):
    if isinstance(value, dict):
        if target in value:
            return True
        for key in ("model_uid", "uid", "id", "model_name"):
            if value.get(key) == target:
                return True
        return any(contains_target(item) for item in value.values())
    if isinstance(value, list):
        return any(contains_target(item) for item in value)
    if isinstance(value, str):
        return value == target
    return False

sys.exit(0 if contains_target(data) else 1)
PY
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
    ps -p "${pid}" -o command= 2>/dev/null | grep -q "start-f5-mlx.sh watchdog"
    return
  fi
}

port_is_listening() {
  if command_exists lsof; then
    lsof -nP -iTCP:"${F5_MLX_PORT}" -sTCP:LISTEN >/dev/null 2>&1
    return
  fi
  if command_exists nc; then
    nc -z 127.0.0.1 "${F5_MLX_PORT}" >/dev/null 2>&1
    return
  fi
  return 1
}

listener_pids() {
  command_exists lsof || return 0
  lsof -nP -tiTCP:"${F5_MLX_PORT}" -sTCP:LISTEN 2>/dev/null || true
}

server_uses_expected_env() {
  command_exists ps || return 0

  local expected_prefix pid command_line found_server
  expected_prefix="$(conda_env_prefix 2>/dev/null || true)"
  [ -n "${expected_prefix}" ] || return 0

  found_server=false
  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command_line}" in
      *f5_mlx_openai_server.py*)
        found_server=true
        case "${command_line}" in
          *"${expected_prefix}/bin/python"*)
            return 0
            ;;
        esac
        ;;
    esac
  done <<EOF
$(listener_pids)
EOF

  if [ "${found_server}" = "true" ]; then
    return 1
  fi
  return 0
}

current_server_command() {
  command_exists ps || return 0

  local pid command_line
  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command_line}" in
      *f5_mlx_openai_server.py*)
        printf '%s\n' "${command_line}"
        ;;
    esac
  done <<EOF
$(listener_pids)
EOF
}

ensure_conda_env() {
  mkdir -p "${DATA_DIR}" "${LOG_DIR}" "${VOICE_DIR}" "${HF_HOME_DIR}"
  if [ -n "$(env_python_if_exists || true)" ]; then
    info "使用 Conda 环境：$(conda_env_prefix)"
    return
  fi

  [ -n "${CONDA_EXE}" ] || die "未找到 conda，请先安装 Conda 或设置 F5_MLX_CONDA。"
  [ -x "${CONDA_EXE}" ] || die "Conda 不可执行：${CONDA_EXE}"

  if [ -n "${CONDA_ENV_DIR}" ]; then
    info "创建 F5-TTS MLX Conda 路径环境：${CONDA_ENV_DIR}"
    # shellcheck disable=SC2086
    "${CONDA_EXE}" create -y ${CONDA_CREATE_ARGS} -p "${CONDA_ENV_DIR}" "python=${CONDA_PYTHON_VERSION}" pip
  else
    info "创建 F5-TTS MLX Conda 命名环境：${CONDA_ENV_NAME}"
    # shellcheck disable=SC2086
    "${CONDA_EXE}" create -y ${CONDA_CREATE_ARGS} -n "${CONDA_ENV_NAME}" "python=${CONDA_PYTHON_VERSION}" pip
  fi
}

deps_ready() {
  "$(env_python)" - <<'PY' >/dev/null 2>&1
import importlib.util
import sys

required = ["f5_tts_mlx", "fastapi", "uvicorn", "soundfile", "mlx"]
missing = [name for name in required if importlib.util.find_spec(name) is None]
sys.exit(1 if missing else 0)
PY
}

ensure_deps() {
  if deps_ready; then
    return
  fi

  info "安装 F5-TTS MLX 依赖。首次安装会比较久。"
  "$(env_python)" -m pip install -U pip
  local pip_packages=()
  read -r -a pip_packages <<< "${F5_MLX_PIP_SPECS}"
  "$(env_python)" -m pip install -U "${pip_packages[@]}"
}

ensure_reference_note() {
  mkdir -p "${VOICE_DIR}"
  local note_file="${VOICE_DIR}/README.md"
  if [ -f "${note_file}" ]; then
    return
  fi
  {
    printf '# F5-TTS MLX 参考音频\n\n'
    printf '请放置 5-10 秒左右、干净人声、mono、24kHz 的 wav 文件，例如：voice_01.wav。\n'
    printf '同名 txt 文件写入这段参考音频的逐字稿，例如：voice_01.txt。\n\n'
    printf '也可以运行：\n\n'
    printf '```bash\n'
    printf './start-f5-mlx.sh prepare-voice /path/to/input.wav "参考音频中说的话" voice_01\n'
    printf '```\n'
  } >"${note_file}"
}

reference_ready() {
  [ -f "${REF_AUDIO}" ] || return 1
  if [ -n "${REF_TEXT}" ]; then
    return 0
  fi
  [ -s "${REF_TEXT_FILE}" ]
}

ensure_reference_ready() {
  ensure_reference_note
  if reference_ready; then
    return
  fi

  warn "F5-TTS 需要参考音频和对应文字稿。"
  warn "当前检查：ref_audio=${REF_AUDIO}, ref_text=${REF_TEXT:-<empty>}, ref_text_file=${REF_TEXT_FILE}"
  warn "准备方式：${SCRIPT_PATH} prepare-voice /path/to/input.wav \"参考音频中说的话\" ${VOICE}"
  if [ "${REQUIRE_REFERENCE}" = "true" ]; then
    die "缺少 F5-TTS 参考音频或文字稿。可设置 F5_MLX_REQUIRE_REFERENCE=false 只启动服务。"
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

    if [ -f "${PID_FILE}" ] && ! pid_is_alive; then
      die "F5-TTS MLX 服务进程已退出，请查看日志：${LOG_FILE}"
    fi

    now="$(date +%s)"
    if [ $((now - start_ts)) -ge "${START_TIMEOUT}" ]; then
      die "等待 F5-TTS MLX 服务启动超时，请查看日志：${LOG_FILE}"
    fi

    sleep 2
  done
}

start_f5_server() {
  if server_available; then
    if server_uses_expected_env; then
      info "F5-TTS MLX 服务已可用：${F5_MLX_ENDPOINT}"
      return
    fi

    warn "端口 ${F5_MLX_PORT} 上已有服务，不是当前 Conda 环境：$(conda_env_prefix)"
    current_server_command | while IFS= read -r command_line; do
      warn "当前进程：${command_line}"
    done

    if [ "${REPLACE_STALE_SERVER}" = "true" ]; then
      warn "按 F5_MLX_REPLACE_STALE_SERVER=true 停止旧服务并重启。"
      stop_f5_server
    else
      die "请先停止旧 F5-TTS MLX 服务，或设置 F5_MLX_REPLACE_STALE_SERVER=true。"
    fi
  fi

  if port_is_listening; then
    local server_command
    server_command="$(current_server_command || true)"
    if [ -n "${server_command}" ]; then
      warn "端口 ${F5_MLX_PORT} 上已有 F5-TTS MLX 服务，但 /health 不可用。"
      if [ "${REPLACE_STALE_SERVER}" = "true" ]; then
        stop_f5_server
      else
        die "请先停止当前 F5-TTS MLX 服务，或设置 F5_MLX_REPLACE_STALE_SERVER=true。"
      fi
    else
      die "端口 ${F5_MLX_PORT} 已被占用，但不是 F5-TTS MLX 服务。请检查占用进程。"
    fi
  fi

  info "启动 F5-TTS MLX 服务：${F5_MLX_ENDPOINT}"
  export F5_MLX_MODEL_NAME="${MODEL_NAME}"
  export F5_MLX_QUANTIZATION_BITS="${QUANTIZATION_BITS}"
  export F5_MLX_DEFAULT_REF_AUDIO="${REF_AUDIO}"
  export F5_MLX_DEFAULT_REF_TEXT="${REF_TEXT}"
  export F5_MLX_DEFAULT_REF_TEXT_FILE="${REF_TEXT_FILE}"
  export F5_MLX_VOICE_DIR="${VOICE_DIR}"
  export F5_MLX_DEFAULT_FORMAT="${FORMAT}"
  export F5_MLX_SPEED="${SPEED}"
  export F5_MLX_ESTIMATE_DURATION="${ESTIMATE_DURATION}"
  export F5_MLX_STEPS="${STEPS}"
  export F5_MLX_METHOD="${METHOD}"
  export F5_MLX_CFG="${CFG}"
  export F5_MLX_SWAY_COEF="${SWAY_COEF}"
  export HF_HOME="${HF_HOME_DIR}"
  export HF_HUB_CACHE="${HF_HOME_DIR}/hub"
  export HF_ENDPOINT="${HF_ENDPOINT}"
  export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET}"
  start_detached_process \
    "${LOG_FILE}" \
    "$(env_python)" \
    "${SERVER_FILE}" \
    --host "${F5_MLX_HOST}" \
    --port "${F5_MLX_PORT}" \
    --log-dir "${LOG_DIR}" \
    >"${PID_FILE}"
  wait_for_server
}

launch_model() {
  if [ "${PRELOAD_MODEL}" != "true" ]; then
    info "模型预加载未启用：F5_MLX_PRELOAD_MODEL=${PRELOAD_MODEL}"
    return
  fi

  if model_is_running; then
    info "F5-TTS MLX 模型已运行：${MODEL_NAME}"
    return
  fi

  info "预加载 F5-TTS MLX 模型：name=${MODEL_NAME}, q=${QUANTIZATION_BITS:-none}"
  local tmp_file http_code query response_preview
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/f5-mlx-load.XXXXXX")"
  query="$(model_query_string)"
  http_code="$(
    curl -sS \
      --max-time "${START_TIMEOUT}" \
      -o "${tmp_file}" \
      -w '%{http_code}' \
      -X POST "${F5_MLX_ENDPOINT}/v1/models?${query}" 2>/dev/null || true
  )"

  if [ "${http_code}" != "200" ]; then
    response_preview="$(head -c 500 "${tmp_file}" 2>/dev/null | tr '\n' ' ' || true)"
    rm -f "${tmp_file}"
    die "F5-TTS MLX 模型预加载失败：HTTP=${http_code:-unknown}，响应=${response_preview:-<empty>}，日志：${LOG_FILE}"
  fi
  rm -f "${tmp_file}"

  if model_is_running; then
    info "F5-TTS MLX 模型 ${MODEL_NAME} 已进入运行列表。"
    return
  fi
  die "F5-TTS MLX 模型预加载返回成功，但未进入运行列表。"
}

start_f5_inference() {
  ensure_conda_env
  ensure_deps
  start_f5_server
  launch_model
}

probe_model_audio() {
  command_exists curl || die "未找到 curl，无法检测 F5-TTS MLX 模型。"
  ensure_reference_ready

  local tmp_base tmp_file http_code response_preview
  tmp_base="$(mktemp "${TMPDIR:-/tmp}/f5-mlx-probe.XXXXXX")"
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

  response_preview="$(head -c 500 "${tmp_file}" 2>/dev/null | tr '\n' ' ' || true)"
  warn "F5-TTS MLX 音频探测失败：HTTP=${http_code:-unknown}，响应=${response_preview:-<empty>}"
  rm -f "${tmp_file}"
  return 1
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
  [ "$(container_env_value XIAOZHI_TTS_FORMAT)" = "${XIAOZHI_TTS_FORMAT}" ] || return 1
  [ "$(container_env_value XIAOZHI_TTS_LANG_CODE)" = "${XIAOZHI_TTS_LANG_CODE}" ] || return 1
}

export_xiaozhi_tts_env() {
  export XIAOZHI_TTS_MODE="local"
  export XIAOZHI_TTS_PROVIDER="${F5_MLX_XIAOZHI_TTS_PROVIDER:-CustomTTS}"
  export XIAOZHI_TTS_URL="${CONTAINER_TTS_URL}"
  export XIAOZHI_TTS_MODEL="${MODEL_NAME}"
  export XIAOZHI_TTS_VOICE="${VOICE}"
  export XIAOZHI_TTS_FORMAT="${FORMAT}"
  export XIAOZHI_TTS_SPEED="${SPEED}"
  export XIAOZHI_TTS_STREAM="${STREAM}"
  export XIAOZHI_TTS_LANG_CODE="${LANG_CODE}"
  export XIAOZHI_TTS_KWARGS_JSON="${XIAOZHI_TTS_KWARGS_JSON:-}"
}

start_xiaozhi_server() {
  command_exists docker || die "未找到 docker。"
  [ -f "${COMPOSE_FILE}" ] || die "未找到 Compose 文件：${COMPOSE_FILE}"

  export_xiaozhi_tts_env

  if container_is_running; then
    if container_matches_expected_tts_env; then
      info "Docker 容器 ${CONTAINER_NAME} 已按 F5-TTS MLX 配置运行，跳过启动。"
      return
    fi

    warn "Docker 容器 ${CONTAINER_NAME} 已运行，但 TTS 环境不是当前 F5-TTS MLX 配置。"
    warn "当前 URL：$(container_env_value XIAOZHI_TTS_URL)，当前模型：$(container_env_value XIAOZHI_TTS_MODEL)，当前音色：$(container_env_value XIAOZHI_TTS_VOICE)"
    if [ "${RECREATE_MISMATCHED_CONTAINER}" != "true" ]; then
      die "请先停止旧容器，或设置 F5_MLX_RECREATE_MISMATCHED_CONTAINER=true。"
    fi
    warn "按 F5_MLX_RECREATE_MISMATCHED_CONTAINER=true 重建容器。"
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

stop_pid_process() {
  local pid="$1"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" >/dev/null 2>&1 || return 1

  info "停止 F5-TTS MLX 服务进程 pid=${pid}。"
  kill "${pid}" >/dev/null 2>&1 || true

  local i
  for i in {1..15}; do
    if ! kill -0 "${pid}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  warn "F5-TTS MLX 服务进程 pid=${pid} 未正常退出，强制停止。"
  kill -KILL "${pid}" >/dev/null 2>&1 || true
}

stop_listening_server_processes() {
  command_exists lsof || return 0

  local pid command_line
  while IFS= read -r pid; do
    [ -n "${pid}" ] || continue
    command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
    case "${command_line}" in
      *f5_mlx_openai_server.py*)
        stop_pid_process "${pid}" || true
        ;;
    esac
  done <<EOF
$(listener_pids)
EOF
}

stop_f5_server() {
  if pid_is_alive; then
    stop_pid_process "$(cat "${PID_FILE}")" || true
    rm -f "${PID_FILE}"
    return
  fi

  rm -f "${PID_FILE}"
  if port_is_listening; then
    stop_listening_server_processes
    if port_is_listening; then
      warn "端口 ${F5_MLX_PORT} 仍在监听；未发现由 f5_mlx_openai_server.py 启动的匹配进程。"
    fi
  else
    info "F5-TTS MLX 服务未运行。"
  fi
}

stop_competing_watchdogs() {
  if [ "${STOP_COMPETING_WATCHDOGS}" != "true" ]; then
    return
  fi

  local script_name pid_file pid command_line
  for script_name in start-qwen3-mlx.sh start-kokoro-mlx.sh; do
    for pid_file in "${SCRIPT_DIR}"/data/*/*watchdog*.pid; do
      [ -f "${pid_file}" ] || continue
      pid="$(cat "${pid_file}" 2>/dev/null || true)"
      [ -n "${pid}" ] || continue
      kill -0 "${pid}" >/dev/null 2>&1 || continue
      command_line="$(ps -p "${pid}" -o command= 2>/dev/null || true)"
      case "${command_line}" in
        *"${script_name}"*"watchdog"*)
          warn "停止可能争用 xiaozhi 容器的后台守护：${script_name} pid=${pid}"
          kill "${pid}" >/dev/null 2>&1 || true
          ;;
      esac
    done
  done
}

start_watchdog() {
  if [ "${WATCHDOG_ENABLED}" != "true" ]; then
    info "后台守护未启用：F5_MLX_WATCHDOG_ENABLED=${WATCHDOG_ENABLED}"
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
      warn "后台守护检测到 F5-TTS MLX 状态不完整，尝试恢复。"
      (start_f5_inference) || warn "后台守护恢复 F5-TTS MLX 失败。"
    fi

    export_xiaozhi_tts_env
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
  info "xiaozhi 默认 TTS 音色：${XIAOZHI_CONFIG_TTS_PROVIDER}/${XIAOZHI_CONFIG_VOICE}"
  info "F5 注入给 xiaozhi 的音色：${VOICE}"
  if [ "${http_code}" = "200" ]; then
    info "F5-TTS MLX 服务：运行中 ${F5_MLX_ENDPOINT}"
    if ! server_uses_expected_env; then
      warn "当前 F5-TTS MLX 服务不是 ${CONDA_ENV_NAME} 环境启动的，start 会自动替换旧服务。"
      current_server_command | while IFS= read -r command_line; do
        warn "当前进程：${command_line}"
      done
    fi
  elif [ -n "${http_code}" ] && [ "${http_code}" != "000" ]; then
    warn "F5-TTS MLX 服务：有响应但不可用 ${F5_MLX_ENDPOINT}，/health HTTP=${http_code}"
  else
    info "F5-TTS MLX 服务：未运行"
  fi

  if model_is_running; then
    info "F5-TTS MLX 模型：运行中 ${MODEL_NAME}"
  else
    info "F5-TTS MLX 模型：未运行 ${MODEL_NAME}"
  fi

  if reference_ready; then
    info "参考音频：已配置 ${REF_AUDIO}"
    if [ -n "${REF_TEXT}" ]; then
      info "参考文本：已从脚本默认值或 F5_MLX_REF_TEXT 配置"
    else
      info "参考文本：已配置 ${REF_TEXT_FILE}"
    fi
  else
    warn "参考音频：未完整配置 ${REF_AUDIO} + ${REF_TEXT_FILE}"
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
  info "F5-TTS MLX 日志：${LOG_FILE}"
  info "后台守护日志：${WATCHDOG_LOG_FILE}"
}

prepare_voice() {
  local input_audio="${1:-}"
  local ref_text="${2:-}"
  local voice_name="${3:-${VOICE}}"

  [ -n "${input_audio}" ] || die "缺少输入音频：prepare-voice INPUT_AUDIO REF_TEXT [VOICE]"
  [ -f "${input_audio}" ] || die "输入音频不存在：${input_audio}"
  [ -n "${ref_text}" ] || die "缺少参考音频文字稿：prepare-voice INPUT_AUDIO REF_TEXT [VOICE]"
  command_exists ffmpeg || die "未找到 ffmpeg，无法转换参考音频。"

  mkdir -p "${VOICE_DIR}"
  local output_audio="${VOICE_DIR}/${voice_name}.wav"
  local output_text="${VOICE_DIR}/${voice_name}.txt"
  info "转换参考音频为 24kHz mono wav：${output_audio}"
  ffmpeg -nostdin -y -i "${input_audio}" -ac 1 -ar 24000 -sample_fmt s16 -t 10 "${output_audio}" >/dev/null 2>&1
  printf '%s\n' "${ref_text}" >"${output_text}"
  info "参考音频文字稿已写入：${output_text}"
}

start_all() {
  info "工作目录：${REPO_ROOT}"
  refresh_watchdog_for_start
  stop_competing_watchdogs
  ensure_reference_ready
  start_f5_inference
  start_xiaozhi_server
  start_watchdog
  info "启动流程完成。"
  info "F5-TTS MLX endpoint：${F5_MLX_ENDPOINT}"
  info "TTS endpoint for Docker：${CONTAINER_TTS_URL}"
  info "Model：${MODEL_NAME}"
  info "xiaozhi 默认 TTS 音色：${XIAOZHI_CONFIG_TTS_PROVIDER}/${XIAOZHI_CONFIG_VOICE}"
  info "F5 注入给 xiaozhi 的音色：${VOICE}"
  info "F5 参考音频：${REF_AUDIO}"
  info "F5-TTS MLX 日志：${LOG_FILE}"
  info "后台守护日志：${WATCHDOG_LOG_FILE}"
}

stop_all() {
  stop_watchdog
  stop_xiaozhi_server
  stop_f5_server
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
      ensure_reference_note
      ;;
    probe)
      probe_model_audio
      ;;
    prepare-voice)
      shift
      prepare_voice "$@"
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
