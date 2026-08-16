ARG KOKORO_BASE_IMAGE=docker.1panel.live/hwdsl2/kokoro-server:latest
FROM ${KOKORO_BASE_IMAGE}

COPY docker/kokoro-modelscope/patch_local_model.py /opt/src/patch_local_model.py
COPY docker/kokoro-modelscope/run-modelscope.sh /opt/src/run-modelscope.sh

RUN chmod +x /opt/src/run-modelscope.sh \
    && /opt/venv/bin/pip install --no-cache-dir -i https://mirrors.aliyun.com/pypi/simple/ modelscope

CMD ["/opt/src/run-modelscope.sh"]
