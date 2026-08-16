import asyncio
import struct

from core.transports.mqtt_connection import MqttTransportConnection, build_device_topics


class FakeMqttClient:
    def __init__(self):
        self.published = []

    def publish(self, topic, payload, qos=0):
        self.published.append((topic, payload, qos))


def test_build_device_topics_normalizes_prefix():
    topics = build_device_topics("xiaozhi/device/", "device-001")

    assert topics == {
        "up_json": "xiaozhi/device/device-001/up/json",
        "up_audio": "xiaozhi/device/device-001/up/audio",
        "down_json": "xiaozhi/device/device-001/down/json",
        "down_audio": "xiaozhi/device/device-001/down/audio",
        "status": "xiaozhi/device/device-001/status",
    }


def test_send_routes_text_to_down_json_with_json_qos():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device", json_qos=1, audio_qos=0)

    asyncio.run(conn.send('{"type":"hello"}'))

    assert client.published == [
        ("xiaozhi/device/device-001/down/json", b'{"type":"hello"}', 1)
    ]


def test_send_routes_unicode_text_as_utf8_bytes():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device", json_qos=1, audio_qos=0)

    asyncio.run(conn.send('{"type":"tts","text":"你好"}'))

    assert client.published == [
        ("xiaozhi/device/device-001/down/json", '{"type":"tts","text":"你好"}'.encode("utf-8"), 1)
    ]


def test_send_routes_bytes_to_down_audio_with_audio_qos():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device", json_qos=1, audio_qos=0)

    asyncio.run(conn.send(b"opus"))

    topic, payload, qos = client.published[0]
    assert topic == "xiaozhi/device/device-001/down/audio"
    assert qos == 0
    assert payload[:2] == b"\x01\x00"
    assert struct.unpack("!H", payload[2:4])[0] == 4
    assert struct.unpack("!I", payload[12:16])[0] == 4
    assert payload[16:] == b"opus"


def test_send_routes_bytes_to_down_audio_with_default_audio_qos():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device")

    asyncio.run(conn.send(b"opus"))

    topic, payload, qos = client.published[0]
    assert topic == "xiaozhi/device/device-001/down/audio"
    assert qos == 0
    assert payload[16:] == b"opus"


def test_send_preserves_already_packed_down_audio():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device", json_qos=1, audio_qos=0)
    packet = b"\x01\x00" + struct.pack("!HIII", 4, 1, 123, 4) + b"opus"

    asyncio.run(conn.send(packet))

    topic, payload, qos = client.published[0]
    assert topic == "xiaozhi/device/device-001/down/audio"
    assert qos == 0
    assert payload == packet


def test_send_preserves_bundled_down_audio():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device", json_qos=1, audio_qos=0)
    body = struct.pack("!H", 4) + b"opus" + struct.pack("!H", 5) + b"opus2"
    packet = b"\x02\x00" + struct.pack("!HIII", len(body), 7, 123, 2) + body

    asyncio.run(conn.send(packet))

    topic, payload, qos = client.published[0]
    assert topic == "xiaozhi/device/device-001/down/audio"
    assert qos == 0
    assert payload == packet


def test_request_path_marks_mqtt_transport_connection():
    conn = MqttTransportConnection("device-001", FakeMqttClient(), "xiaozhi/device")

    assert "from=mqtt_transport" in conn.request.path


def test_receive_audio_preserves_mqtt_transport_header():
    conn = MqttTransportConnection("device-001", FakeMqttClient(), "xiaozhi/device")
    packet = b"\x01\x00" + struct.pack("!HIII", 4, 1, 123, 4) + b"opus"

    async def receive_once():
        await conn.receive_audio(packet)
        return await conn.__anext__()

    assert asyncio.run(receive_once()) == packet
