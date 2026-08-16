import asyncio
import concurrent.futures
import os
import queue
import sys
import time
import types
import threading

sys.modules.setdefault(
    "opuslib_next",
    types.SimpleNamespace(
        Decoder=lambda *args, **kwargs: None,
        Encoder=lambda *args, **kwargs: None,
        constants=types.SimpleNamespace(APPLICATION_AUDIO=2049),
    ),
)
sys.modules.setdefault(
    "pydub",
    types.SimpleNamespace(AudioSegment=types.SimpleNamespace()),
)


class DummyLogger:
    def bind(self, *args, **kwargs):
        return self

    def debug(self, *args, **kwargs):
        pass

    def info(self, *args, **kwargs):
        pass

    def warning(self, *args, **kwargs):
        pass

    def error(self, *args, **kwargs):
        pass


sys.modules["config.logger"] = types.SimpleNamespace(
    setup_logging=lambda *args, **kwargs: DummyLogger()
)

from core.handle import sendAudioHandle as send_audio_handle
from core.providers.tts import base as tts_base
from core.providers.tts.base import TTSProviderBase
from core.providers.tts.dto.dto import SentenceType


class FakeWebSocket:
    def __init__(self):
        self.sent = []

    async def send(self, payload):
        self.sent.append(payload)


class FakeConn:
    def __init__(self):
        self.config = {
            "tts_audio_send_delay": 0,
            "mqtt_audio_bundle_frames": 4,
            "mqtt_audio_bundle_flush_ms": 100,
        }
        self.conn_from_mqtt_gateway = True
        self.client_abort = False
        self.client_aec = False
        self.sentence_id = "sentence-1"
        self.websocket = FakeWebSocket()
        self.last_activity_time = 0


def _decode_mqtt_audio_bundle(packet):
    assert packet[0] == send_audio_handle.MQTT_AUDIO_PACKET_TYPE_BUNDLE
    body_size = int.from_bytes(packet[2:4], "big")
    first_sequence = int.from_bytes(packet[4:8], "big")
    frame_count = int.from_bytes(packet[12:16], "big")
    body = packet[16:16 + body_size]
    frames = []
    offset = 0
    for _ in range(frame_count):
        frame_size = int.from_bytes(body[offset:offset + 2], "big")
        offset += 2
        frames.append(body[offset:offset + frame_size])
        offset += frame_size
    return first_sequence, frames


def test_mqtt_audio_default_sends_bundles_without_rate_queue():
    conn = FakeConn()

    asyncio.run(send_audio_handle.sendAudio(conn, [b"opus"] * 6, frame_duration=60))

    assert not hasattr(conn, "audio_rate_controller")
    assert len(conn.websocket.sent) == 2
    first_sequence, first_frames = _decode_mqtt_audio_bundle(conn.websocket.sent[0])
    second_sequence, second_frames = _decode_mqtt_audio_bundle(conn.websocket.sent[1])
    assert first_sequence == 0
    assert first_frames == [b"opus"] * 4
    assert second_sequence == 4
    assert second_frames == [b"opus"] * 2
    assert conn.mqtt_audio_flow_control["playback_ms"] == 360


def test_mqtt_audio_bundles_frames_across_single_frame_calls():
    async def send_frames(conn):
        await send_audio_handle.sendAudio(conn, b"one", frame_duration=60)
        await send_audio_handle.sendAudio(conn, b"two", frame_duration=60)
        await send_audio_handle.sendAudio(conn, b"three", frame_duration=60)
        assert conn.websocket.sent == []
        await send_audio_handle.sendAudio(conn, b"four", frame_duration=60)

    conn = FakeConn()

    asyncio.run(send_frames(conn))

    assert len(conn.websocket.sent) == 1
    first_sequence, first_frames = _decode_mqtt_audio_bundle(conn.websocket.sent[0])
    assert first_sequence == 0
    assert first_frames == [b"one", b"two", b"three", b"four"]
    assert conn.mqtt_audio_flow_control["playback_ms"] == 240


class FakeTTSConn:
    conn_from_mqtt_gateway = True
    sentence_id = "sentence-1"
    sample_rate = 16000
    client_abort = False
    config = {}


class FakeTTSProvider(TTSProviderBase):
    async def text_to_speak(self, text, output_file):
        if text == "slow":
            await asyncio.sleep(0.05)
        return text.encode("utf-8")


class FakeEmptyFileTTSProvider(TTSProviderBase):
    async def text_to_speak(self, text, output_file):
        if output_file:
            os.makedirs(os.path.dirname(output_file), exist_ok=True)
            with open(output_file, "wb"):
                pass
        return None


def test_parallel_mqtt_tts_emits_in_text_order(monkeypatch):
    def fake_audio_bytes_to_data_stream(audio_bytes, **kwargs):
        kwargs["callback"](b"opus:" + audio_bytes)

    monkeypatch.setattr(
        tts_base, "audio_bytes_to_data_stream", fake_audio_bytes_to_data_stream
    )
    provider = FakeTTSProvider(
        {
            "mqtt_tts_parallel_enabled": True,
            "mqtt_tts_parallel_workers": 2,
            "mqtt_tts_parallel_window": 2,
        },
        delete_audio_file=True,
    )
    provider.conn = FakeTTSConn()
    provider.opus_encoder = None

    try:
        provider._submit_parallel_tts("slow", "sentence-1")
        provider._submit_parallel_tts("fast", "sentence-1")

        for _ in range(20):
            fast_future = provider._parallel_tts_futures.get(1)
            if fast_future and fast_future.done():
                break
            time.sleep(0.01)
        assert provider._parallel_tts_futures.get(1).done()

        provider._drain_parallel_tts(block=False)
        assert provider.tts_audio_queue.empty()

        provider._drain_parallel_tts(block=True)
        for _ in range(20):
            if provider.tts_audio_queue.qsize() >= 4:
                break
            time.sleep(0.01)
        items = []
        while True:
            try:
                items.append(provider.tts_audio_queue.get_nowait())
            except queue.Empty:
                break

        assert items == [
            (SentenceType.FIRST, None, "slow", "sentence-1"),
            (SentenceType.MIDDLE, b"opus:slow", None, "sentence-1"),
            (SentenceType.FIRST, None, "fast", "sentence-1"),
            (SentenceType.MIDDLE, b"opus:fast", None, "sentence-1"),
        ]
    finally:
        if provider._parallel_executor is not None:
            provider._parallel_executor.shutdown(wait=True)


def test_process_parallel_tts_does_not_block_when_window_is_full(monkeypatch):
    provider = FakeTTSProvider(
        {
            "mqtt_tts_parallel_enabled": True,
            "mqtt_tts_parallel_workers": 2,
            "mqtt_tts_parallel_window": 2,
        },
        delete_audio_file=True,
    )
    provider.conn = FakeTTSConn()
    drain_calls = []

    def fake_submit_parallel_tts(text, sentence_id):
        future = concurrent.futures.Future()
        with provider._parallel_tts_lock:
            index = provider._parallel_next_submit_index
            provider._parallel_next_submit_index += 1
            provider._parallel_tts_futures[index] = future

    monkeypatch.setattr(provider, "_submit_parallel_tts", fake_submit_parallel_tts)
    monkeypatch.setattr(
        provider,
        "_drain_parallel_tts",
        lambda block=False, timeout=None: drain_calls.append((block, timeout)),
    )

    provider._process_tts_segment("first", "sentence-1")
    provider._process_tts_segment("second", "sentence-1")

    assert drain_calls == [(False, None), (False, None)]


def test_parallel_tts_timeout_waits_for_stalled_segment_and_keeps_order(monkeypatch):
    def fake_audio_bytes_to_data_stream(audio_bytes, **kwargs):
        kwargs["callback"](b"opus:" + audio_bytes)

    monkeypatch.setattr(
        tts_base, "audio_bytes_to_data_stream", fake_audio_bytes_to_data_stream
    )
    provider = FakeTTSProvider(
        {
            "mqtt_tts_parallel_enabled": True,
            "mqtt_tts_parallel_workers": 2,
            "mqtt_tts_order_timeout": 1,
        },
        delete_audio_file=True,
    )
    provider.conn = FakeTTSConn()
    provider.opus_encoder = None
    delayed_future = concurrent.futures.Future()
    ready_future = concurrent.futures.Future()
    ready_future.set_result(
        {
            "ok": True,
            "text": "second",
            "sentence_id": "sentence-1",
            "audio_bytes": b"second",
            "tmp_file": None,
        }
    )
    provider._parallel_tts_futures = {
        0: delayed_future,
        1: ready_future,
    }

    def complete_delayed_future():
        time.sleep(0.02)
        delayed_future.set_result(
            {
                "ok": True,
                "text": "first",
                "sentence_id": "sentence-1",
                "audio_bytes": b"first",
                "tmp_file": None,
            }
        )

    thread = threading.Thread(target=complete_delayed_future)
    thread.start()

    assert provider._drain_parallel_tts(block=True, timeout=0) is False
    assert provider._parallel_tts_futures == {
        0: delayed_future,
        1: ready_future,
    }
    thread.join()
    assert provider._drain_parallel_tts(block=True, timeout=0) is True

    assert not delayed_future.cancelled()
    assert provider._parallel_tts_futures == {}
    assert provider._parallel_next_emit_index == 2

    items = []
    while True:
        try:
            items.append(provider.tts_audio_queue.get_nowait())
        except queue.Empty:
            break

    assert items == [
        (SentenceType.FIRST, None, "first", "sentence-1"),
        (SentenceType.MIDDLE, b"opus:first", None, "sentence-1"),
        (SentenceType.FIRST, None, "second", "sentence-1"),
        (SentenceType.MIDDLE, b"opus:second", None, "sentence-1"),
    ]


def test_tts_file_generation_rejects_empty_file(tmp_path):
    provider = FakeEmptyFileTTSProvider(
        {"tts_max_retries": 1, "tts_timeout": 1},
        delete_audio_file=False,
    )
    provider.generate_filename = lambda extension=".wav": str(tmp_path / "empty.wav")

    result = provider._generate_tts_result("empty", "sentence-1")

    assert result["ok"] is False


def test_mqtt_segment_text_uses_punctuation_boundary():
    provider = FakeTTSProvider(
        {"mqtt_tts_min_segment_chars": 8},
        delete_audio_file=True,
    )
    provider.conn = types.SimpleNamespace(
        conn_from_mqtt_gateway=True,
        config={},
    )
    provider.tts_text_buff = ["abcdefgh,ijklmnop."]

    assert provider._get_segment_text() == "abcdefgh"
    assert provider.processed_chars == len("abcdefgh,")


def test_mqtt_segment_text_waits_for_punctuation():
    provider = FakeTTSProvider(
        {"mqtt_tts_min_segment_chars": 8},
        delete_audio_file=True,
    )
    provider.conn = types.SimpleNamespace(
        conn_from_mqtt_gateway=True,
        config={},
    )
    provider.tts_text_buff = ["abcdefghijklmnop"]

    assert provider._get_segment_text() is None
    assert provider.processed_chars == 0


def test_mqtt_segment_text_normalizes_pause_punctuation():
    provider = FakeTTSProvider(
        {"mqtt_tts_min_segment_chars": 1},
        delete_audio_file=True,
    )
    provider.conn = types.SimpleNamespace(
        conn_from_mqtt_gateway=True,
        config={},
    )
    provider.tts_text_buff = ["ESP32-S3,"]

    assert provider._get_segment_text() == "ESP32-S3"
    assert provider.processed_chars == len("ESP32-S3,")


def test_mqtt_segment_text_can_drain_multiple_ready_segments():
    provider = FakeTTSProvider(
        {"mqtt_tts_min_segment_chars": 1},
        delete_audio_file=True,
    )
    provider.conn = types.SimpleNamespace(
        conn_from_mqtt_gateway=True,
        config={},
    )
    provider.tts_text_buff = ["first,second!third~tail"]
    segments = []

    while True:
        segment_text = provider._get_segment_text()
        if not segment_text:
            break
        segments.append(segment_text)

    assert segments == ["first", "second", "third"]
    assert provider.processed_chars == len("first,second!third~")


class FakeStopEvent:
    def __init__(self):
        self.stopped = False

    def is_set(self):
        return self.stopped

    def set(self):
        self.stopped = True


def test_mqtt_audio_play_thread_sends_without_waiting_for_last(monkeypatch):
    provider = FakeTTSProvider({}, delete_audio_file=True)
    stop_event = FakeStopEvent()
    provider.conn = types.SimpleNamespace(
        stop_event=stop_event,
        client_abort=False,
        conn_from_mqtt_gateway=True,
        loop=None,
        max_output_size=0,
        headers={},
        sentence_id="sentence-1",
    )
    sent = []

    async def fake_send_audio_message(conn, sentence_type, audios, text, sentence_id):
        sent.append((sentence_type, audios, text, sentence_id))
        stop_event.set()

    class FakeFuture:
        def result(self):
            return None

    def fake_run_coroutine_threadsafe(coro, loop):
        asyncio.run(coro)
        return FakeFuture()

    monkeypatch.setattr(tts_base, "sendAudioMessage", fake_send_audio_message)
    monkeypatch.setattr(
        tts_base.asyncio, "run_coroutine_threadsafe", fake_run_coroutine_threadsafe
    )
    provider.tts_audio_queue.put(
        (SentenceType.FIRST, None, "第一段", "sentence-1")
    )

    provider._audio_play_priority_thread()

    assert sent == [(SentenceType.FIRST, None, "第一段", "sentence-1")]
