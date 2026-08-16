import os
import io
import json
import sys
import time
import shutil
import psutil
import asyncio

from funasr import AutoModel
from config.logger import setup_logging
from typing import Optional, Tuple, List
from core.providers.asr.utils import asr_text_content, lang_tag_filter
from core.providers.asr.base import ASRProviderBase
from core.providers.asr.dto.dto import InterfaceType

TAG = __name__
logger = setup_logging()

MAX_RETRIES = 2
RETRY_DELAY = 1  # 重试延迟（秒）


# 捕获标准输出
class CaptureOutput:
    def __enter__(self):
        self._output = io.StringIO()
        self._original_stdout = sys.stdout
        sys.stdout = self._output

    def __exit__(self, exc_type, exc_value, traceback):
        sys.stdout = self._original_stdout
        self.output = self._output.getvalue()
        self._output.close()

        # 将捕获到的内容通过 logger 输出
        if self.output:
            logger.bind(tag=TAG).info(self.output.strip())


class ASRProvider(ASRProviderBase):
    def __init__(self, config: dict, delete_audio_file: bool):
        super().__init__()
        
        # 内存检测，要求大于2G
        min_mem_bytes = 2 * 1024 * 1024 * 1024
        try:
            total_mem = psutil.virtual_memory().total
        except RuntimeError as e:
            logger.bind(tag=TAG).warning(f"获取系统内存信息失败，跳过FunASR内存检测: {e}")
        else:
            if total_mem < min_mem_bytes:
                logger.bind(tag=TAG).error(f"可用内存不足2G，当前仅有 {total_mem / (1024*1024):.2f} MB，可能无法启动FunASR")
        
        self.interface_type = InterfaceType.LOCAL
        self.model_dir = config.get("model_dir")
        self.output_dir = config.get("output_dir")  # 修正配置键名
        self.language = config.get("language", "auto")
        self.delete_audio_file = delete_audio_file
        self._validate_model_files()

        # 确保输出目录存在
        os.makedirs(self.output_dir, exist_ok=True)
        with CaptureOutput():
            self.model = AutoModel(
                model=self.model_dir,
                vad_kwargs={"max_single_segment_time": 30000},
                disable_update=True,
                hub="hf",
                # device="cuda:0",  # 启用GPU加速
            )

    def _validate_model_files(self):
        if not self.model_dir:
            raise ValueError("FunASR 模型目录未配置")

        config_path = os.path.join(self.model_dir, "configuration.json")
        if not os.path.isfile(config_path):
            raise FileNotFoundError(f"FunASR 模型配置不存在: {config_path}")

        with open(config_path, "r", encoding="utf-8") as fp:
            model_config = json.load(fp)

        file_metas = model_config.get("file_path_metas", {})
        required_files = []
        init_param = file_metas.get("init_param")
        if init_param:
            required_files.append(init_param)
        frontend_conf = file_metas.get("frontend_conf", {})
        cmvn_file = frontend_conf.get("cmvn_file")
        if cmvn_file:
            required_files.append(cmvn_file)

        missing_files = [
            name
            for name in required_files
            if not os.path.isfile(os.path.join(self.model_dir, name))
        ]
        if missing_files:
            raise FileNotFoundError(
                "FunASR 模型文件不完整，缺少: "
                + ", ".join(missing_files)
                + "；请先补齐本地 models/SenseVoiceSmall 后再重建 Docker 镜像"
            )

    async def speech_to_text(
        self, opus_data: List[bytes], session_id: str, artifacts=None
    ) -> Tuple[Optional[str], Optional[str]]:
        """语音转文本主处理逻辑"""
        retry_count = 0
        
        while retry_count < MAX_RETRIES:
            try:
                if artifacts is None:
                    return "", None

                # 语音识别 - 使用线程池避免阻塞事件循环
                start_time = time.time()
                result = await asyncio.to_thread(
                    self.model.generate,
                    input=artifacts.pcm_bytes,
                    cache={},
                    language=self.language,
                    use_itn=True,
                    batch_size_s=60,
                )
                text = lang_tag_filter(result[0]["text"])
                logger.bind(tag=TAG).debug(
                    f"语音识别耗时: {time.time() - start_time:.3f}s | 结果: {asr_text_content(text)}"
                )

                return text, artifacts.file_path

            except OSError as e:
                retry_count += 1
                if retry_count >= MAX_RETRIES:
                    logger.bind(tag=TAG).error(
                        f"语音识别失败（已重试{retry_count}次）: {e}", exc_info=True
                    )
                    return "", None
                logger.bind(tag=TAG).warning(
                    f"语音识别失败，正在重试（{retry_count}/{MAX_RETRIES}）: {e}"
                )
                time.sleep(RETRY_DELAY)

            except Exception as e:
                logger.bind(tag=TAG).error(f"语音识别失败: {e}", exc_info=True)
                return "", None
