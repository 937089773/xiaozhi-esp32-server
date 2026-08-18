#!/usr/bin/env bash
set -euo pipefail

cd /opt/index-tts

export PATH="/opt/index-tts/.venv/bin:/root/.local/bin:${PATH}"
export PYTHONPATH="/opt/index-tts:${PYTHONPATH:-}"

MODEL_DIR="${INDEXTTS_MODEL_DIR:-/opt/index-tts/checkpoints}"
MODEL_ID="${INDEXTTS_MODEL_ID:-IndexTeam/IndexTTS-2.5}"
DOWNLOAD_SOURCE="${INDEXTTS_DOWNLOAD_SOURCE:-modelscope}"
FETCH_EXAMPLES="${INDEXTTS_FETCH_EXAMPLES:-true}"

export INDEXTTS_MODEL_DIR="${MODEL_DIR}"
export HF_HOME="${HF_HOME:-/opt/index-tts/checkpoints/hf_cache}"
export HF_HUB_CACHE="${HF_HUB_CACHE:-/opt/index-tts/checkpoints/hf_cache}"
export HF_HUB_DISABLE_XET="${HF_HUB_DISABLE_XET:-1}"

mkdir -p "${MODEL_DIR}" "${HF_HOME}" "${HF_HUB_CACHE}"

if [ ! -f "${MODEL_DIR}/config.yaml" ]; then
  echo "Downloading IndexTTS model from ${DOWNLOAD_SOURCE}: ${MODEL_ID}"
  case "${DOWNLOAD_SOURCE}" in
    modelscope)
      modelscope download --model "${MODEL_ID}" --local_dir "${MODEL_DIR}"
      ;;
    huggingface|hf)
      if command -v hf >/dev/null 2>&1; then
        hf download "${MODEL_ID}" --local-dir="${MODEL_DIR}"
      else
        huggingface-cli download "${MODEL_ID}" --local-dir="${MODEL_DIR}"
      fi
      ;;
    none|skip)
      echo "Skipping model download because INDEXTTS_DOWNLOAD_SOURCE=${DOWNLOAD_SOURCE}"
      ;;
    *)
      echo "Unsupported INDEXTTS_DOWNLOAD_SOURCE: ${DOWNLOAD_SOURCE}" >&2
      exit 1
      ;;
  esac
fi

if [ ! -f "${MODEL_DIR}/config.yaml" ]; then
  echo "Missing IndexTTS model config: ${MODEL_DIR}/config.yaml" >&2
  exit 1
fi

if [ "${FETCH_EXAMPLES}" = "true" ] || [ "${FETCH_EXAMPLES}" = "1" ]; then
  python - <<'PY'
from indextts.utils.examples_downloader import ensure_examples_available

ensure_examples_available()
PY
fi

exec uvicorn api_server_xiaozhi:app --host 0.0.0.0 --port "${INDEXTTS_PORT:-8002}" --workers 1
