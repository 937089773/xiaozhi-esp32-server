#!/bin/bash
set -euo pipefail

export PATH="/opt/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

MODEL_DIR="${KOKORO_LOCAL_MODEL:-/var/lib/kokoro/modelscope/Kokoro-82M}"
MODEL_ID="${KOKORO_MODELSCOPE_MODEL:-hexgrad/Kokoro-82M}"
VOICE_ID="${KOKORO_VOICE:-zf_xiaoxiao}"

export KOKORO_LOCAL_MODEL="$MODEL_DIR"

mkdir -p "$MODEL_DIR"

if [ ! -f "$MODEL_DIR/config.json" ] \
  || [ ! -f "$MODEL_DIR/kokoro-v1_0.pth" ] \
  || [ ! -f "$MODEL_DIR/voices/${VOICE_ID}.pt" ]; then
  echo "Downloading Kokoro model from ModelScope: ${MODEL_ID}"
  modelscope download --model "$MODEL_ID" --local_dir "$MODEL_DIR"
fi

python - <<'PY'
from pathlib import Path
import os
root = Path(os.environ["KOKORO_LOCAL_MODEL"])
voice = os.environ.get("KOKORO_VOICE", "zf_xiaoxiao")
required = [
    root / "config.json",
    root / "kokoro-v1_0.pth",
    root / "voices" / f"{voice}.pt",
]
missing = [str(path) for path in required if not path.is_file()]
if missing:
    raise SystemExit("Missing Kokoro model files: " + ", ".join(missing))
PY

python - <<'PY'
from pathlib import Path
api_server = Path("/opt/src/api_server.py")
text = api_server.read_text(encoding="utf-8")
patch = "import patch_local_model  # noqa: F401\n"
if patch not in text:
    marker = "import uvicorn\n"
    text = text.replace(marker, marker + patch, 1)
    api_server.write_text(text, encoding="utf-8")
PY

exec /opt/src/run.sh
