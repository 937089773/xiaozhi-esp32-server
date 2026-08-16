# 本地 TTS Docker 部署

当前分支通过 Docker Compose 里的环境值区分在线 TTS 和本地 TTS，代码启动时会读取 `XIAOZHI_TTS_MODE`。

## 在线 TTS

默认的 `main/xiaozhi-server/docker-compose.yml` 使用在线 TTS：

```bash
docker compose -f main/xiaozhi-server/docker-compose.yml up -d --build
```

`main/xiaozhi-server/docker-compose_all.yml` 也带有同样的在线默认值。

默认值：

```env
XIAOZHI_TTS_MODE=online
XIAOZHI_TTS_PROVIDER=EdgeTTS
```

## 本地 TTS

新的 `main/xiaozhi-server/docker-compose.local-tts.yml` 会同时启动 server 和 Kokoro 本地 TTS 服务。
默认会基于 `docker.1panel.live/hwdsl2/kokoro-server:latest` 构建一个本地 Kokoro 包装镜像。
包装镜像启动前会从 ModelScope 下载 `hexgrad/Kokoro-82M`，并让 Kokoro 优先读取本地模型目录。

```bash
docker compose -f main/xiaozhi-server/docker-compose.local-tts.yml up -d --build
```

默认值：

```env
HF_ENDPOINT=https://hf-mirror.com
HF_HUB_DISABLE_XET=1
KOKORO_MODELSCOPE_MODEL=hexgrad/Kokoro-82M
XIAOZHI_TTS_MODE=local
XIAOZHI_TTS_PROVIDER=CustomTTS
XIAOZHI_TTS_URL=http://kokoro-tts:8880/v1/audio/speech
XIAOZHI_TTS_MODEL=kokoro
XIAOZHI_TTS_VOICE=zf_xiaoxiao
XIAOZHI_TTS_FORMAT=mp3
XIAOZHI_TTS_SPEED=1
XIAOZHI_TTS_STREAM=false
```

`XIAOZHI_TTS_URL` 使用的是 Compose 服务名 `kokoro-tts`，因为 server 在容器内访问本地 TTS 容器时不能使用宿主机的 `127.0.0.1`。

如需改用 GPU 镜像，可以设置：

```env
XIAOZHI_LOCAL_TTS_IMAGE=docker.1panel.live/hwdsl2/kokoro-server:cuda
```
