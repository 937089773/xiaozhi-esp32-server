import os
import asyncio
import json
import yaml
from collections.abc import Mapping
from config.manage_api_client import (
    init_service,
    get_server_config,
    get_agent_models,
    get_correct_words,
    DeviceNotFoundException,
    DeviceBindException,
)


def get_project_dir():
    """获取项目根目录"""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__))) + "/"


def read_config(config_path):
    with open(config_path, "r", encoding="utf-8") as file:
        config = yaml.safe_load(file)
    return config


async def load_config():
    """加载配置文件"""
    from core.utils.cache.manager import cache_manager, CacheType

    # 检查缓存
    cached_config = cache_manager.get(CacheType.CONFIG, "main_config")
    if cached_config is not None:
        return cached_config

    default_config_path = get_project_dir() + "config.yaml"
    custom_config_path = get_project_dir() + "data/.config.yaml"

    # 加载默认配置
    default_config = read_config(default_config_path)
    custom_config = read_config(custom_config_path)

    if custom_config.get("manager-api", {}).get("url"):
        config = await get_config_from_api_async(custom_config)
    else:
        # 合并配置
        config = merge_configs(default_config, custom_config)
    apply_tts_mode_from_env(config)
    # 初始化目录
    ensure_directories(config)

    # 缓存配置
    cache_manager.set(CacheType.CONFIG, "main_config", config)
    return config


async def get_config_from_api_async(config):
    """从Java API获取配置（异步版本）"""
    # 初始化API客户端
    init_service(config)

    # 获取服务器配置
    config_data = await get_server_config()
    if config_data is None:
        raise Exception("Failed to fetch server config from API")

    config_data["read_config_from_api"] = True
    config_data["manager-api"] = {
        "url": config["manager-api"].get("url", ""),
        "secret": config["manager-api"].get("secret", ""),
    }
    auth_enabled = config_data.get("server", {}).get("auth", {}).get("enabled", False)
    # server的配置以本地为准
    if config.get("server"):
        config_data["server"] = {
            "ip": config["server"].get("ip", ""),
            "port": config["server"].get("port", ""),
            "http_port": config["server"].get("http_port", ""),
            "vision_explain": config["server"].get("vision_explain", ""),
            "auth_key": config["server"].get("auth_key", ""),
        }
    config_data["server"]["auth"] = {"enabled": auth_enabled}
    # 如果服务器没有prompt_template，则从本地配置读取
    if not config_data.get("prompt_template"):
        config_data["prompt_template"] = config.get("prompt_template")
    return config_data


def apply_tts_mode_from_env(config, environ=None):
    """通过 Docker Compose 注入的环境变量切换在线/本地 TTS。"""
    if environ is None:
        environ = os.environ
    tts_mode = _env_value(environ, "XIAOZHI_TTS_MODE")
    if not tts_mode:
        return config

    normalized_mode = tts_mode.lower()
    if normalized_mode in ("api", "cloud"):
        normalized_mode = "online"
    elif normalized_mode in ("offline", "docker"):
        normalized_mode = "local"

    if normalized_mode not in ("online", "local"):
        raise ValueError(
            "XIAOZHI_TTS_MODE must be 'online' or 'local', "
            f"got: {tts_mode}"
        )

    selected_module = config.setdefault("selected_module", {})
    tts_configs = config.setdefault("TTS", {})
    provider = _env_value(environ, "XIAOZHI_TTS_PROVIDER")
    if not provider:
        provider = (
            "CustomTTS"
            if normalized_mode == "local"
            else selected_module.get("TTS", "EdgeTTS")
        )

    selected_module["TTS"] = provider
    config["tts_mode"] = normalized_mode

    if normalized_mode == "local" and provider == "CustomTTS":
        _apply_local_custom_tts_config(tts_configs, environ)
    elif provider not in tts_configs:
        raise ValueError(f"TTS provider '{provider}' is not configured")

    return config


def _apply_local_custom_tts_config(tts_configs, environ):
    custom_tts = dict(tts_configs.get("CustomTTS", {}))
    response_format = _env_value(environ, "XIAOZHI_TTS_FORMAT", "mp3")
    speed = _env_value(environ, "XIAOZHI_TTS_SPEED", "1")

    params = dict(custom_tts.get("params") or {})
    params.update(
        {
            "model": _env_value(environ, "XIAOZHI_TTS_MODEL", "kokoro"),
            "input": "{prompt_text}",
            "voice": _env_value(environ, "XIAOZHI_TTS_VOICE", "zf_xiaoxiao"),
            "response_format": response_format,
            "speed": _coerce_scalar(speed),
            "stream": _env_bool(environ, "XIAOZHI_TTS_STREAM", False),
        }
    )
    lang_code = _env_value(environ, "XIAOZHI_TTS_LANG_CODE")
    if lang_code:
        params["lang_code"] = lang_code
    kwargs_json = _env_value(environ, "XIAOZHI_TTS_KWARGS_JSON")
    if kwargs_json:
        params["kwargs"] = _normalize_json_object(kwargs_json, "XIAOZHI_TTS_KWARGS_JSON")
    else:
        tts_kwargs = {}
        language = _env_value(environ, "XIAOZHI_TTS_LANGUAGE")
        if language:
            tts_kwargs["language"] = language
        instruct = _env_value(environ, "XIAOZHI_TTS_INSTRUCT")
        if instruct:
            tts_kwargs["instruct"] = instruct
        if tts_kwargs:
            params["kwargs"] = json.dumps(tts_kwargs, ensure_ascii=False)

    custom_tts.update(
        {
            "type": "custom",
            "method": _env_value(environ, "XIAOZHI_TTS_METHOD", "POST"),
            "url": _env_value(
                environ,
                "XIAOZHI_TTS_URL",
                "http://kokoro-tts:8880/v1/audio/speech",
            ),
            "params": params,
            "headers": custom_tts.get("headers") or {},
            "format": response_format,
            "output_dir": custom_tts.get("output_dir", "tmp/"),
        }
    )
    tts_configs["CustomTTS"] = custom_tts


def _env_value(environ, key, default=None):
    value = environ.get(key)
    if value is None:
        return default
    value = str(value).strip()
    return value if value else default


def _env_bool(environ, key, default=False):
    value = _env_value(environ, key)
    if value is None:
        return default
    return value.lower() in ("1", "true", "yes", "on")


def _coerce_scalar(value):
    if not isinstance(value, str):
        return value
    try:
        if "." in value:
            return float(value)
        return int(value)
    except ValueError:
        return value


def _normalize_json_object(value, key):
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{key} must be a valid JSON object") from exc
    if not isinstance(parsed, dict):
        raise ValueError(f"{key} must be a JSON object")
    return json.dumps(parsed, ensure_ascii=False)


async def get_private_config_from_api(config, device_id, client_id):
    """从Java API获取私有配置"""
    results = await asyncio.gather(
        get_agent_models(device_id, client_id, config["selected_module"]),
        get_correct_words(device_id),
        return_exceptions=True,
    )
    agent_result = results[0]
    correct_words = results[1] if not isinstance(results[1], Exception) else None

    # 抛出业务异常
    if isinstance(agent_result, DeviceNotFoundException):
        raise agent_result
    if isinstance(agent_result, DeviceBindException):
        raise agent_result

    private_config = agent_result if not isinstance(agent_result, Exception) else {}
    if correct_words:
        private_config["correct_words"] = correct_words
    return private_config


def ensure_directories(config):
    """确保所有配置路径存在"""
    dirs_to_create = set()
    project_dir = get_project_dir()  # 获取项目根目录
    # 日志文件目录
    log_dir = config.get("log", {}).get("log_dir", "tmp")
    dirs_to_create.add(os.path.join(project_dir, log_dir))

    # ASR/TTS模块输出目录
    for module in ["ASR", "TTS"]:
        if config.get(module) is None:
            continue
        for provider in config.get(module, {}).values():
            output_dir = provider.get("output_dir", "")
            if output_dir:
                dirs_to_create.add(output_dir)

    # 根据selected_module创建模型目录
    selected_modules = config.get("selected_module", {})
    for module_type in ["ASR", "LLM", "TTS"]:
        selected_provider = selected_modules.get(module_type)
        if not selected_provider:
            continue
        if config.get(module_type) is None:
            continue
        if config.get(selected_provider) is None:
            continue
        provider_config = config.get(module_type, {}).get(selected_provider, {})
        output_dir = provider_config.get("output_dir")
        if output_dir:
            full_model_dir = os.path.join(project_dir, output_dir)
            dirs_to_create.add(full_model_dir)

    # 统一创建目录（保留原data目录创建）
    for dir_path in dirs_to_create:
        try:
            os.makedirs(dir_path, exist_ok=True)
        except PermissionError:
            print(f"警告：无法创建目录 {dir_path}，请检查写入权限")


def merge_configs(default_config, custom_config):
    """
    递归合并配置，custom_config优先级更高

    Args:
        default_config: 默认配置
        custom_config: 用户自定义配置

    Returns:
        合并后的配置
    """
    if not isinstance(default_config, Mapping) or not isinstance(
        custom_config, Mapping
    ):
        return custom_config

    merged = dict(default_config)

    for key, value in custom_config.items():
        if (
            key in merged
            and isinstance(merged[key], Mapping)
            and isinstance(value, Mapping)
        ):
            merged[key] = merge_configs(merged[key], value)
        else:
            merged[key] = value

    return merged
