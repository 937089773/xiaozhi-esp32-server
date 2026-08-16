import pytest

from config.config_loader import apply_tts_mode_from_env


def _base_config():
    return {
        "selected_module": {
            "TTS": "EdgeTTS",
        },
        "TTS": {
            "EdgeTTS": {
                "type": "edge",
                "voice": "zh-CN-XiaoxiaoNeural",
            },
            "CustomTTS": {
                "type": "custom",
                "params": {
                    "voice": "old_voice",
                },
                "output_dir": "tmp/",
            },
        },
    }


def test_tts_mode_local_uses_custom_kokoro_from_env():
    config = _base_config()

    apply_tts_mode_from_env(
        config,
        {
            "XIAOZHI_TTS_MODE": "local",
            "XIAOZHI_TTS_URL": "http://kokoro-tts:8880/v1/audio/speech",
            "XIAOZHI_TTS_VOICE": "zf_xiaoxiao",
            "XIAOZHI_TTS_FORMAT": "wav",
            "XIAOZHI_TTS_SPEED": "1.25",
        },
    )

    assert config["tts_mode"] == "local"
    assert config["selected_module"]["TTS"] == "CustomTTS"
    custom_tts = config["TTS"]["CustomTTS"]
    assert custom_tts["url"] == "http://kokoro-tts:8880/v1/audio/speech"
    assert custom_tts["method"] == "POST"
    assert custom_tts["format"] == "wav"
    assert custom_tts["params"]["model"] == "kokoro"
    assert custom_tts["params"]["input"] == "{prompt_text}"
    assert custom_tts["params"]["voice"] == "zf_xiaoxiao"
    assert custom_tts["params"]["response_format"] == "wav"
    assert custom_tts["params"]["speed"] == 1.25
    assert custom_tts["params"]["stream"] is False


def test_tts_mode_online_uses_provider_from_env():
    config = _base_config()

    apply_tts_mode_from_env(
        config,
        {
            "XIAOZHI_TTS_MODE": "online",
            "XIAOZHI_TTS_PROVIDER": "EdgeTTS",
        },
    )

    assert config["tts_mode"] == "online"
    assert config["selected_module"]["TTS"] == "EdgeTTS"


def test_tts_mode_ignores_empty_env():
    config = _base_config()

    apply_tts_mode_from_env(config, {})

    assert "tts_mode" not in config
    assert config["selected_module"]["TTS"] == "EdgeTTS"


def test_tts_mode_rejects_unknown_mode():
    with pytest.raises(ValueError, match="XIAOZHI_TTS_MODE"):
        apply_tts_mode_from_env(_base_config(), {"XIAOZHI_TTS_MODE": "bad"})
