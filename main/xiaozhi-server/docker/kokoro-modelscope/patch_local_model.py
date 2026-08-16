import os
from pathlib import Path

import kokoro.model as kokoro_model
import kokoro.pipeline as kokoro_pipeline

_original_model_download = kokoro_model.hf_hub_download
_original_pipeline_download = kokoro_pipeline.hf_hub_download


def _local_model_root():
    root = os.environ.get("KOKORO_LOCAL_MODEL", "").strip()
    if not root:
        return None
    path = Path(root).resolve()
    return path if path.is_dir() else None


def _resolve_local_file(filename):
    root = _local_model_root()
    if root is None or not filename:
        return None
    candidate = (root / filename).resolve()
    try:
        candidate.relative_to(root)
    except ValueError:
        return None
    return str(candidate) if candidate.is_file() else None


def _download_from_local_or_hub(original_download):
    def wrapper(*args, **kwargs):
        filename = kwargs.get("filename")
        if filename is None and len(args) >= 2:
            filename = args[1]
        local_file = _resolve_local_file(filename)
        if local_file:
            return local_file
        return original_download(*args, **kwargs)

    return wrapper


kokoro_model.hf_hub_download = _download_from_local_or_hub(_original_model_download)
kokoro_pipeline.hf_hub_download = _download_from_local_or_hub(
    _original_pipeline_download
)
