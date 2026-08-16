import json
import time
import asyncio
import opuslib_next
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from core.connection import ConnectionHandler
from core.utils import textUtils
from core.utils.util import audio_to_data
from core.providers.tts.dto.dto import SentenceType
from core.utils.audioRateController import AudioRateController

TAG = __name__
# 音频帧时长（毫秒）
AUDIO_FRAME_DURATION = 60
# 预缓冲包数量，直接发送以减少延迟
PRE_BUFFER_COUNT = 5
MQTT_AUDIO_PACKET_TYPE_SINGLE = 1
MQTT_AUDIO_PACKET_TYPE_BUNDLE = 2
MQTT_AUDIO_BUNDLE_DEFAULT_FRAMES = 4
MQTT_AUDIO_BUNDLE_MAX_FRAMES = 8
MQTT_AUDIO_BUNDLE_DEFAULT_MAX_BYTES = 4096
MQTT_AUDIO_BUNDLE_DEFAULT_FLUSH_MS = 60


async def sendAudioMessage(conn: "ConnectionHandler", sentenceType, audios, text, sentence_id=None):
    # 跳过旧句子残留音频
    if sentence_id is not None and sentence_id != conn.sentence_id:
        return

    if conn.tts.tts_audio_first_sentence:
        conn.logger.bind(tag=TAG).info(f"发送第一段语音: {text}")
        conn.tts.tts_audio_first_sentence = False

    if sentenceType == SentenceType.FIRST:
        # 同一句子的后续消息加入流控队列，其他情况立即发送
        if (
            not getattr(conn, "conn_from_mqtt_gateway", False)
            and hasattr(conn, "audio_rate_controller")
            and conn.audio_rate_controller
            and getattr(conn, "audio_flow_control", {}).get("sentence_id")
            == conn.sentence_id
        ):
            conn.audio_rate_controller.add_message(
                lambda: send_tts_message(conn, "sentence_start", text)
            )
        else:
            # 新句子或流控器未初始化，立即发送
            await send_tts_message(conn, "sentence_start", text)

    await sendAudio(conn, audios)
    if getattr(conn, "conn_from_mqtt_gateway", False) and sentenceType == SentenceType.LAST:
        await _flush_mqtt_pending_audio(conn, reason="sentence_end")
    # 发送句子开始消息
    if sentenceType is not SentenceType.MIDDLE:
        conn.logger.bind(tag=TAG).info(f"发送音频消息: {sentenceType}, {text}")

    # 发送结束消息（如果是最后一个文本）
    # 通话需要维持speaking状态
    if not conn.calling and sentenceType == SentenceType.LAST:
        await send_tts_message(conn, "stop", None)
        if conn.close_after_chat:
            await conn.close()


async def _wait_for_audio_completion(conn: "ConnectionHandler"):
    """
    等待音频队列清空并等待预缓冲包播放完成

    Args:
        conn: 连接对象
    """
    if getattr(conn, "conn_from_mqtt_gateway", False):
        await _flush_mqtt_pending_audio(conn, reason="wait_completion")
        flow_control = getattr(conn, "mqtt_audio_flow_control", None)
        if not flow_control:
            return
        playback_started_at = flow_control.get("playback_started_at")
        playback_ms = flow_control.get("playback_ms", 0)
        if playback_started_at is None or playback_ms <= 0:
            return
        remaining = playback_ms / 1000.0 - (time.monotonic() - playback_started_at)
        if remaining > 0:
            await asyncio.sleep(remaining + 0.24)
        _log_conn_debug(conn, "MQTT音频播放预计完成")
        return

    if hasattr(conn, "audio_rate_controller") and conn.audio_rate_controller:
        rate_controller = conn.audio_rate_controller
        conn.logger.bind(tag=TAG).debug(
            f"等待音频发送完成，队列中还有 {len(rate_controller.queue)} 个包"
        )
        await rate_controller.queue_empty_event.wait()

        # 等待预缓冲包播放完成
        # 前N个包直接发送，增加2个网络抖动包，需要额外等待它们在客户端播放完成
        frame_duration_ms = rate_controller.frame_duration
        pre_buffer_playback_time = (PRE_BUFFER_COUNT + 2) * frame_duration_ms / 1000.0
        await asyncio.sleep(pre_buffer_playback_time)

        conn.logger.bind(tag=TAG).debug("音频发送完成")


async def _send_to_mqtt_gateway(
    conn: "ConnectionHandler", opus_packet, timestamp, sequence
):
    """
    发送带16字节头部的opus数据包给mqtt_gateway，同时缓存音频用于AEC处理
    Args:
        conn: 连接对象
        opus_packet: opus数据包
        timestamp: 时间戳
        sequence: 序列号
    """
    _cache_mqtt_aec_audio(conn, opus_packet, timestamp)

    # 为opus数据包添加16字节头部
    header = bytearray(16)
    header[0] = MQTT_AUDIO_PACKET_TYPE_SINGLE  # type
    header[2:4] = len(opus_packet).to_bytes(2, "big")  # payload length
    header[4:8] = sequence.to_bytes(4, "big")  # sequence
    header[8:12] = timestamp.to_bytes(4, "big")  # 时间戳
    header[12:16] = len(opus_packet).to_bytes(4, "big")  # opus长度

    # 发送包含头部的完整数据包
    complete_packet = bytes(header) + bytes(opus_packet)
    await conn.websocket.send(complete_packet)


def _cache_mqtt_aec_audio(conn: "ConnectionHandler", opus_packet, timestamp):
    if not getattr(conn, "client_aec", False) or timestamp <= 0:
        return
    if not hasattr(conn, "aec_audio_cache"):
        conn.aec_audio_cache = {}
        conn.aec_audio_cache_time = {}
        conn._send_opus_decoder = opuslib_next.Decoder(16000, 1)
    pcm_data = conn._send_opus_decoder.decode(bytes(opus_packet), 960)
    conn.aec_audio_cache[timestamp] = bytes(pcm_data)
    conn.aec_audio_cache_time[timestamp] = time.time()


async def sendAudio(
    conn: "ConnectionHandler", audios, frame_duration=AUDIO_FRAME_DURATION
):
    """
    发送音频包，使用 AudioRateController 进行精确的流量控制

    Args:
        conn: 连接对象
        audios: 单个opus包(bytes) 或 opus包列表
        frame_duration: 帧时长（毫秒），默认使用全局常量AUDIO_FRAME_DURATION
    """
    if audios is None or len(audios) == 0:
        return

    send_delay_ms = conn.config.get("tts_audio_send_delay", -1)
    send_delay = send_delay_ms / 1000.0
    is_single_packet = isinstance(audios, bytes)
    audio_list = [audios] if is_single_packet else list(audios)

    if getattr(conn, "conn_from_mqtt_gateway", False):
        flow_control = _get_or_create_mqtt_flow_control(conn)
        await _send_mqtt_audio_bundles(conn, audio_list, flow_control, frame_duration)
        return

    # 初始化或获取 RateController
    rate_controller, flow_control = _get_or_create_rate_controller(
        conn, frame_duration, is_single_packet
    )

    # 发送音频包
    await _send_audio_with_rate_control(
        conn, audio_list, rate_controller, flow_control, send_delay
    )


def _get_or_create_mqtt_flow_control(conn: "ConnectionHandler"):
    if hasattr(conn, "audio_rate_controller") and conn.audio_rate_controller:
        conn.audio_rate_controller.stop_sending()
        conn.audio_rate_controller = None

    flow_control = getattr(conn, "mqtt_audio_flow_control", None)
    if (
        not flow_control
        or flow_control.get("sentence_id") != conn.sentence_id
    ):
        conn.mqtt_audio_flow_control = {
            "packet_count": 0,
            "sequence": 0,
            "sentence_id": conn.sentence_id,
            "playback_started_at": None,
            "playback_ms": 0,
            "published_messages": 0,
            "pending_frames": [],
            "pending_bytes": 0,
            "bundle_flush_task": None,
            "frame_duration": AUDIO_FRAME_DURATION,
        }
    return conn.mqtt_audio_flow_control


def _get_config_int(conn: "ConnectionHandler", key, default, minimum, maximum):
    try:
        value = int(conn.config.get(key, default))
    except (TypeError, ValueError):
        value = default
    return max(minimum, min(maximum, value))


def _log_conn_debug(conn: "ConnectionHandler", message, *args):
    logger = getattr(conn, "logger", None)
    if logger is not None:
        logger.bind(tag=TAG).debug(message, *args)


async def _flush_mqtt_pending_audio(
    conn: "ConnectionHandler",
    flow_control=None,
    frame_duration=None,
    reason=None,
):
    if flow_control is None:
        flow_control = getattr(conn, "mqtt_audio_flow_control", None)
    if not flow_control:
        return

    current_task = asyncio.current_task()
    flush_task = flow_control.get("bundle_flush_task")
    if flush_task and flush_task is not current_task:
        if not flush_task.done():
            flush_task.cancel()
        flow_control["bundle_flush_task"] = None
    elif flush_task is current_task or flush_task is None:
        flow_control["bundle_flush_task"] = None

    frames = flow_control.get("pending_frames") or []
    if not frames:
        flow_control["pending_bytes"] = 0
        return

    if conn.client_abort:
        flow_control["pending_frames"] = []
        flow_control["pending_bytes"] = 0
        return

    frame_duration = frame_duration or flow_control.get(
        "frame_duration", AUDIO_FRAME_DURATION
    )
    flow_control["pending_frames"] = []
    flow_control["pending_bytes"] = 0
    await _do_send_mqtt_audio_chunk(conn, frames, flow_control, frame_duration)
    _log_conn_debug(
        conn,
        "MQTT音频打包发送: frames={}, reason={}, pending=0",
        len(frames),
        reason or "manual",
    )


def _schedule_mqtt_pending_audio_flush(conn, flow_control, frame_duration):
    flush_task = flow_control.get("bundle_flush_task")
    if flush_task and not flush_task.done():
        return

    flush_ms = _get_config_int(
        conn,
        "mqtt_audio_bundle_flush_ms",
        MQTT_AUDIO_BUNDLE_DEFAULT_FLUSH_MS,
        10,
        500,
    )

    async def flush_later():
        try:
            await asyncio.sleep(flush_ms / 1000.0)
            await _flush_mqtt_pending_audio(
                conn,
                flow_control,
                frame_duration,
                reason="timer",
            )
        except asyncio.CancelledError:
            pass

    flow_control["bundle_flush_task"] = asyncio.create_task(flush_later())


async def _send_mqtt_audio_bundles(
    conn: "ConnectionHandler", audio_list, flow_control, frame_duration
):
    bundle_frames = _get_config_int(
        conn,
        "mqtt_audio_bundle_frames",
        MQTT_AUDIO_BUNDLE_DEFAULT_FRAMES,
        1,
        MQTT_AUDIO_BUNDLE_MAX_FRAMES,
    )
    max_bundle_bytes = _get_config_int(
        conn,
        "mqtt_audio_bundle_max_bytes",
        MQTT_AUDIO_BUNDLE_DEFAULT_MAX_BYTES,
        256,
        60000,
    )
    flow_control["frame_duration"] = frame_duration
    message_count_before = flow_control.get("published_messages", 0)
    frame_count_before = flow_control.get("packet_count", 0)

    for packet in audio_list:
        if conn.client_abort:
            await _flush_mqtt_pending_audio(
                conn, flow_control, frame_duration, reason="abort"
            )
            return

        packet_size = len(packet)
        if packet_size > 0xFFFF:
            await _flush_mqtt_pending_audio(
                conn, flow_control, frame_duration, reason="oversized"
            )
            _log_conn_debug(conn, "跳过过大的MQTT音频帧: bytes={}", packet_size)
            continue

        pending_frames = flow_control.setdefault("pending_frames", [])
        pending_bytes = flow_control.get("pending_bytes", 0)
        next_size = pending_bytes + 2 + packet_size
        if pending_frames and (
            len(pending_frames) >= bundle_frames or next_size > max_bundle_bytes
        ):
            await _flush_mqtt_pending_audio(
                conn, flow_control, frame_duration, reason="bundle_full"
            )
            pending_frames = flow_control.setdefault("pending_frames", [])
            pending_bytes = flow_control.get("pending_bytes", 0)

        pending_frames.append(packet)
        flow_control["pending_bytes"] = pending_bytes + 2 + packet_size

        if len(pending_frames) >= bundle_frames:
            await _flush_mqtt_pending_audio(
                conn, flow_control, frame_duration, reason="bundle_full"
            )
        else:
            _schedule_mqtt_pending_audio_flush(conn, flow_control, frame_duration)

    if len(audio_list) > 1:
        await _flush_mqtt_pending_audio(
            conn, flow_control, frame_duration, reason="batch_end"
        )

    sent_frames = flow_control.get("packet_count", 0) - frame_count_before
    sent_messages = flow_control.get("published_messages", 0) - message_count_before
    if sent_frames:
        _log_conn_debug(
            conn,
            "MQTT音频快速发送: frames={}, mqtt_messages={}, bundle_frames={}, max_bytes={}",
            sent_frames,
            sent_messages,
            bundle_frames,
            max_bundle_bytes,
        )


async def _do_send_mqtt_audio_chunk(
    conn: "ConnectionHandler", frames, flow_control, frame_duration
):
    if len(frames) == 1:
        await _do_send_audio(conn, frames[0], flow_control)
        if flow_control.get("playback_started_at") is None:
            flow_control["playback_started_at"] = time.monotonic()
        flow_control["playback_ms"] = flow_control.get("playback_ms", 0) + frame_duration
        flow_control["published_messages"] = flow_control.get("published_messages", 0) + 1
        return

    sequence = flow_control.get("sequence", 0)
    timestamp = int(time.time() * 1000) % (2**32)
    body = bytearray()
    for index, frame in enumerate(frames):
        frame_bytes = bytes(frame)
        body.extend(len(frame_bytes).to_bytes(2, "big"))
        body.extend(frame_bytes)
        _cache_mqtt_aec_audio(
            conn,
            frame_bytes,
            (timestamp + index * frame_duration) % (2**32),
        )

    header = bytearray(16)
    header[0] = MQTT_AUDIO_PACKET_TYPE_BUNDLE
    header[2:4] = len(body).to_bytes(2, "big")
    header[4:8] = sequence.to_bytes(4, "big")
    header[8:12] = timestamp.to_bytes(4, "big")
    header[12:16] = len(frames).to_bytes(4, "big")

    await conn.websocket.send(bytes(header) + bytes(body))
    conn.last_activity_time = time.time() * 1000

    if flow_control.get("playback_started_at") is None:
        flow_control["playback_started_at"] = time.monotonic()
    flow_control["packet_count"] = flow_control.get("packet_count", 0) + len(frames)
    flow_control["sequence"] = sequence + len(frames)
    flow_control["playback_ms"] = flow_control.get("playback_ms", 0) + len(frames) * frame_duration
    flow_control["published_messages"] = flow_control.get("published_messages", 0) + 1


def _get_or_create_rate_controller(
    conn: "ConnectionHandler", frame_duration, is_single_packet
):
    """
    获取或创建 RateController 和 flow_control

    Args:
        conn: 连接对象
        frame_duration: 帧时长
        is_single_packet: 是否单包模式（True: TTS流式单包, False: 批量包）

    Returns:
        (rate_controller, flow_control)
    """
    # 检查是否需要重置控制器
    need_reset = False

    if not hasattr(conn, "audio_rate_controller"):
        # 控制器不存在，需要创建
        need_reset = True
    else:
        rate_controller = conn.audio_rate_controller

        # 后台发送任务已停止, 则需要重置
        if (
            not rate_controller.pending_send_task
            or rate_controller.pending_send_task.done()
        ):
            need_reset = True
        # 当sentence_id 变化，需要重置
        elif (
            getattr(conn, "audio_flow_control", {}).get("sentence_id")
            != conn.sentence_id
        ):
            need_reset = True

    if need_reset:
        # 创建或获取 rate_controller
        if not hasattr(conn, "audio_rate_controller"):
            conn.audio_rate_controller = AudioRateController(frame_duration)
        else:
            conn.audio_rate_controller.reset()

        # 初始化 flow_control
        conn.audio_flow_control = {
            "packet_count": 0,
            "sequence": 0,
            "sentence_id": conn.sentence_id,
        }

        # 启动后台发送循环
        _start_background_sender(
            conn, conn.audio_rate_controller, conn.audio_flow_control
        )

    return conn.audio_rate_controller, conn.audio_flow_control


def _start_background_sender(conn: "ConnectionHandler", rate_controller, flow_control):
    """
    启动后台发送循环任务

    Args:
        conn: 连接对象
        rate_controller: 速率控制器
        flow_control: 流控状态
    """

    async def send_callback(packet):
        # 检查是否应该中止
        if conn.client_abort:
            raise asyncio.CancelledError("客户端已中止")

        conn.last_activity_time = time.time() * 1000
        await _do_send_audio(conn, packet, flow_control)

    # 使用 start_sending 启动后台循环
    rate_controller.start_sending(send_callback)


async def _send_audio_with_rate_control(
    conn: "ConnectionHandler", audio_list, rate_controller, flow_control, send_delay
):
    """
    使用 rate_controller 发送音频包

    Args:
        conn: 连接对象
        audio_list: 音频包列表
        rate_controller: 速率控制器
        flow_control: 流控状态
        send_delay: 固定延迟（秒），-1表示使用动态流控
    """
    for packet in audio_list:
        if conn.client_abort:
            return

        conn.last_activity_time = time.time() * 1000

        # 预缓冲：前N个包直接发送
        if flow_control["packet_count"] < PRE_BUFFER_COUNT:
            await _do_send_audio(conn, packet, flow_control)
        elif send_delay > 0:
            # 固定延迟模式
            await asyncio.sleep(send_delay)
            await _do_send_audio(conn, packet, flow_control)
        else:
            # 动态流控模式：仅添加到队列，由后台循环负责发送
            rate_controller.add_audio(packet)


async def _do_send_audio(conn: "ConnectionHandler", opus_packet, flow_control):
    """
    执行实际的音频发送
    """
    packet_index = flow_control.get("packet_count", 0)
    sequence = flow_control.get("sequence", 0)

    if conn.conn_from_mqtt_gateway:
        # 计算时间戳（基于播放位置）
        start_time = time.time()
        timestamp = int(start_time * 1000) % (2**32)
        await _send_to_mqtt_gateway(conn, opus_packet, timestamp, sequence)
    else:
        # 直接发送opus数据包
        await conn.websocket.send(opus_packet)

    # 更新流控状态
    flow_control["packet_count"] = packet_index + 1
    flow_control["sequence"] = sequence + 1


async def send_tts_message(conn: "ConnectionHandler", state, text=None):
    """发送 TTS 状态消息"""
    if text is None and state == "sentence_start":
        return
    message = {"type": "tts", "state": state, "session_id": conn.session_id}
    if text is not None:
        message["text"] = textUtils.check_emoji(text)

    # TTS播放结束
    if state == "stop":
        # 保存当前的 sentence_id，用于后续判断是否是当前轮次
        current_sentence_id = conn.sentence_id
        # 播放提示音
        tts_notify = conn.config.get("enable_stop_tts_notify", False)
        if tts_notify:
            stop_tts_notify_voice = conn.config.get(
                "stop_tts_notify_voice", "config/assets/tts_notify.mp3"
            )
            audios = await audio_to_data(stop_tts_notify_voice, is_opus=True)
            await sendAudio(conn, audios)
        # 等待所有音频包发送完成
        await _wait_for_audio_completion(conn)

        # 检查是否是当前轮次
        if current_sentence_id != conn.sentence_id:
            return

        # 停止音频发送循环（仅在流控器已初始化时调用）
        if hasattr(conn, "audio_rate_controller") and conn.audio_rate_controller:
            conn.audio_rate_controller.stop_sending()
        conn.clearSpeakStatus()

    # 发送消息到客户端
    await conn.websocket.send(json.dumps(message, ensure_ascii=False))


async def send_stt_message(conn: "ConnectionHandler", text):
    """发送 STT 状态消息"""
    end_prompt_str = conn.config.get("end_prompt", {}).get("prompt")
    if end_prompt_str and end_prompt_str == text:
        await send_tts_message(conn, "start")
        return

    # 解析JSON格式，提取实际的用户说话内容
    display_text = text
    try:
        # 尝试解析JSON格式
        if text.strip().startswith("{") and text.strip().endswith("}"):
            parsed_data = json.loads(text)
            if isinstance(parsed_data, dict) and "content" in parsed_data:
                # 如果是包含说话人信息的JSON格式，只显示content部分
                display_text = parsed_data["content"]
                # 保存说话人信息到conn对象
                if "speaker" in parsed_data:
                    conn.current_speaker = parsed_data["speaker"]
    except (json.JSONDecodeError, TypeError):
        # 如果不是JSON格式，直接使用原始文本
        display_text = text
    stt_text = textUtils.get_string_no_punctuation_or_emoji(display_text)
    await conn.websocket.send(
        json.dumps({"type": "stt", "text": stt_text, "session_id": conn.session_id}, ensure_ascii=False)
    )
    await send_tts_message(conn, "start")
    # 发送start消息后客户端状态会处于说话中状态，同步服务端状态
    conn.client_is_speaking = True


async def send_display_message(conn: "ConnectionHandler", text):
    """发送纯显示消息"""
    message = {
        "type": "stt",
        "text": text,
        "session_id": conn.session_id
    }
    await conn.websocket.send(json.dumps(message, ensure_ascii=False))
