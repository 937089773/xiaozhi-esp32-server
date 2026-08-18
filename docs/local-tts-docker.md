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

## 本地 TTS：Kokoro

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

## 本地 TTS：IndexTTS2.5

`main/xiaozhi-server/docker-compose.local-indextts.yml` 会同时启动 server 和 IndexTTS2.5 本地 TTS 服务。
server 仍使用现有 `CustomTTS` 适配路径，TTS URL 指向 IndexTTS2.5 兼容接口 `http://indextts-tts:8002/v1/audio/speech`。

```bash
docker compose -f main/xiaozhi-server/docker-compose.local-indextts.yml up -d --build
```

默认值：

```env
HF_ENDPOINT=https://hf-mirror.com
HF_HUB_DISABLE_XET=1
INDEXTTS_MODEL_ID=IndexTeam/IndexTTS-2.5
INDEXTTS_DOWNLOAD_SOURCE=modelscope
XIAOZHI_TTS_MODE=local
XIAOZHI_TTS_PROVIDER=CustomTTS
XIAOZHI_TTS_URL=http://indextts-tts:8002/v1/audio/speech
XIAOZHI_TTS_MODEL=IndexTeam/IndexTTS-2.5
XIAOZHI_TTS_VOICE=voice_01
XIAOZHI_TTS_FORMAT=wav
XIAOZHI_TTS_SPEED=1
XIAOZHI_TTS_STREAM=false
XIAOZHI_TTS_LANG_CODE=ZH
```

IndexTTS2.5 使用参考音频克隆音色。默认 `voice_01` 会解析为官方示例音频 `examples/voice_01.wav`；如需自定义音色，把 wav 文件放到 `main/xiaozhi-server/data/indextts/voices/`，然后设置：

```env
XIAOZHI_TTS_VOICE=your_voice.wav
```

IndexTTS2.5 默认按 NVIDIA GPU 环境启动，宿主机需要安装 NVIDIA Container Toolkit；如需在非 NVIDIA 环境调试，可移除 compose 中的 `gpus: all`，并设置 `INDEXTTS_USE_CUDA_KERNEL=false`。IndexTTS2.5 首次启动会下载模型到 `indextts-data` volume，镜像构建和首次启动耗时会明显长于 Kokoro。

## 本地 TTS：Kokoro-82M-zh-MLX（Mac）

`main/xiaozhi-server/docker-compose.local-kokoro-mlx.yml` 用于 Apple Silicon Mac。MLX 依赖 macOS 的 Metal 运行时，Docker Desktop 的 Linux 容器不能直接使用 Mac 的 Metal 加速，所以这个 compose 保持 server 在 Docker 内运行，并通过 `host.docker.internal` 访问 Mac 宿主机上的 Xinference 服务。

推荐使用一键脚本启动。脚本会先检测 Xinference 的 `Kokoro-82M-zh-MLX` 模型是否已经可以合成音频，可以则跳过 inference 启动；否则创建或复用 Python venv，安装 Xinference 和 Kokoro MLX 依赖，后台启动 `xinference-local`，注册并启动 `1038lab/Kokoro-82M-zh-MLX` 自定义音频模型。随后脚本会检测 `xiaozhi-esp32-server` Docker 容器是否已经运行，已运行则跳过，否则启动 compose。

```bash
cd main/xiaozhi-server
./start-kokoro-mlx.sh
```

国内网络可以在启动前增加 Hugging Face 镜像环境变量：

```bash
export HF_ENDPOINT=https://hf-mirror.com
./start-kokoro-mlx.sh
```

脚本默认值：

```env
XINFERENCE_PORT=9997
XINFERENCE_PIP_SPEC=xinference==1.9.1
KOKORO_XINFERENCE_CONDA_ENV_NAME=python12-xiaozhi-tts
KOKORO_XINFERENCE_PYTHON_VERSION=3.12
KOKORO_XINFERENCE_MODEL_NAME=Kokoro-82M-zh-MLX
KOKORO_XINFERENCE_MODEL_UID=Kokoro-82M-zh-MLX
KOKORO_XINFERENCE_MODEL_ID=1038lab/Kokoro-82M-zh-MLX
KOKORO_XINFERENCE_MODEL_FAMILY=Kokoro-MLX
KOKORO_XINFERENCE_VOICE=zf_001
KOKORO_XINFERENCE_LANG_CODE=z
KOKORO_XINFERENCE_FORMAT=wav
KOKORO_XINFERENCE_REGISTER_CUSTOM_MODEL=true
```

脚本默认使用 Conda 命名环境 `python12-xiaozhi-tts`。如果环境已经存在，脚本会复用；如果不存在，脚本会按这个名字创建。也可以手动创建：

```bash
conda create -n python12-xiaozhi-tts python=3.12 pip
```

如果本机 Conda 不在 `PATH` 中，可以显式指定：

```bash
KOKORO_XINFERENCE_CONDA=/opt/anaconda3/bin/conda ./start-kokoro-mlx.sh
```

如果已经手动注册了 Xinference 模型，或者希望使用 Xinference 内置模型名，可以覆盖脚本变量，例如：

```bash
KOKORO_XINFERENCE_REGISTER_CUSTOM_MODEL=false \
KOKORO_XINFERENCE_MODEL_NAME=Kokoro-82M-MLX \
KOKORO_XINFERENCE_MODEL_UID=Kokoro-82M-zh-MLX \
./start-kokoro-mlx.sh
```

Docker Compose 默认值：

```env
XIAOZHI_TTS_MODE=local
XIAOZHI_TTS_PROVIDER=CustomTTS
XIAOZHI_TTS_URL=http://host.docker.internal:9997/v1/audio/speech
XIAOZHI_TTS_MODEL=Kokoro-82M-zh-MLX
XIAOZHI_TTS_VOICE=zf_001
XIAOZHI_TTS_FORMAT=wav
XIAOZHI_TTS_SPEED=1
XIAOZHI_TTS_STREAM=false
XIAOZHI_TTS_LANG_CODE=z
```

如果 Xinference 使用了其他端口，需要同步设置 `XINFERENCE_PORT`，脚本会把 Docker 容器内的 `XIAOZHI_TTS_URL` 自动设置为对应的 `host.docker.internal` 地址。
