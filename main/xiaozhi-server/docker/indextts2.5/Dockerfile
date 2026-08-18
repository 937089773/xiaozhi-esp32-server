ARG INDEXTTS_BASE_IMAGE=nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04
FROM ${INDEXTTS_BASE_IMAGE}

ENV DEBIAN_FRONTEND=noninteractive \
    PATH="/opt/index-tts/.venv/bin:/root/.local/bin:${PATH}" \
    PYTHONPATH="/opt/index-tts"

ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple
ARG UV_DEFAULT_INDEX=https://mirrors.aliyun.com/pypi/simple
ARG INDEXTTS_REPO=https://github.com/index-tts/index-tts.git
ARG INDEXTTS_REF=main

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        ffmpeg \
        git \
        libgl1 \
        libglib2.0-0 \
        libsndfile1 \
        python3 \
        python3-pip \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m pip install --no-cache-dir -i "${PIP_INDEX_URL}" uv

WORKDIR /opt
RUN git clone --depth 1 --branch "${INDEXTTS_REF}" "${INDEXTTS_REPO}" /opt/index-tts

WORKDIR /opt/index-tts
RUN uv sync --no-dev --default-index "${UV_DEFAULT_INDEX}" \
    && uv pip install --python .venv/bin/python --no-cache \
        fastapi \
        huggingface-hub \
        modelscope \
        python-multipart \
        "uvicorn[standard]"

COPY docker/indextts2.5/api_server.py /opt/index-tts/api_server_xiaozhi.py
COPY docker/indextts2.5/run.sh /opt/index-tts/run-xiaozhi.sh

RUN chmod +x /opt/index-tts/run-xiaozhi.sh

EXPOSE 8002

CMD ["/opt/index-tts/run-xiaozhi.sh"]
