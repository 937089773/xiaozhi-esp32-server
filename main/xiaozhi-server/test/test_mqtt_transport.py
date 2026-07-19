import asyncio

from core.transports.mqtt_transport import MqttTransport


class FakeConnection:
    def __init__(self, device_id):
        self.device_id = device_id
        self.json_messages = []
        self.audio_messages = []

    async def receive_json(self, payload):
        self.json_messages.append(payload)

    async def receive_audio(self, payload):
        self.audio_messages.append(payload)


def test_extract_device_id_from_up_topics():
    transport = MqttTransport({"topic_prefix": "xiaozhi/device"})

    assert transport.extract_device_id("xiaozhi/device/device-001/up/json") == "device-001"
    assert transport.extract_device_id("xiaozhi/device/device-001/up/audio") == "device-001"
    assert transport.extract_device_id("xiaozhi/device/device-001/down/json") is None
    assert transport.extract_device_id("other/device-001/up/json") is None


def test_handle_message_routes_json_and_audio_to_connection():
    created = []

    def factory(device_id):
        conn = FakeConnection(device_id)
        created.append(conn)
        return conn

    transport = MqttTransport({"topic_prefix": "xiaozhi/device"}, connection_factory=factory)

    asyncio.run(transport.handle_message("xiaozhi/device/device-001/up/json", b'{"type":"hello"}'))
    asyncio.run(transport.handle_message("xiaozhi/device/device-001/up/audio", b"\x01opus"))

    assert len(created) == 1
    assert created[0].json_messages == ['{"type":"hello"}']
    assert created[0].audio_messages == [b"\x01opus"]
