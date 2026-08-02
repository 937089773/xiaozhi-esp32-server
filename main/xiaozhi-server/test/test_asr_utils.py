import sys
import types


logger_module = types.ModuleType("config.logger")
logger_module.setup_logging = lambda: None
sys.modules["config.logger"] = logger_module

from core.providers.asr.utils import asr_text_content


def test_asr_text_content_reads_dict_content():
    assert asr_text_content({"content": "你好", "language": "zh"}) == "你好"


def test_asr_text_content_accepts_plain_text():
    assert asr_text_content("你好") == "你好"
