import asyncio

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
        ("xiaozhi/device/device-001/down/json", '{"type":"hello"}', 1)
    ]


def test_send_routes_bytes_to_down_audio_with_audio_qos():
    client = FakeMqttClient()
    conn = MqttTransportConnection("device-001", client, "xiaozhi/device", json_qos=1, audio_qos=0)

    asyncio.run(conn.send(b"\x01opus"))

    assert client.published == [
        ("xiaozhi/device/device-001/down/audio", b"\x01opus", 0)
    ]
