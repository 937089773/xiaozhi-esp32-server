import asyncio
from types import SimpleNamespace


_CLOSE_SENTINEL = object()


def build_device_topics(topic_prefix: str, device_id: str) -> dict[str, str]:
    prefix = topic_prefix.rstrip("/")
    base = f"{prefix}/{device_id}"
    return {
        "up_json": f"{base}/up/json",
        "up_audio": f"{base}/up/audio",
        "down_json": f"{base}/down/json",
        "down_audio": f"{base}/down/audio",
        "status": f"{base}/status",
    }


class MqttTransportConnection:
    def __init__(self, device_id: str, client, topic_prefix: str, json_qos: int = 1, audio_qos: int = 0):
        self.device_id = device_id
        self.client = client
        self.topics = build_device_topics(topic_prefix, device_id)
        self.json_qos = json_qos
        self.audio_qos = audio_qos
        self.remote_address = ("mqtt", 0)
        self.request = SimpleNamespace(
            headers={
                "device-id": device_id,
                "client-id": device_id,
                "authorization": "Bearer mqtt-transport",
            },
            path=f"/xiaozhi/v1/?from=mqtt_transport&device-id={device_id}",
        )
        self.closed = False
        self._incoming = asyncio.Queue()

    def __aiter__(self):
        return self

    async def __anext__(self):
        message = await self._incoming.get()
        if message is _CLOSE_SENTINEL:
            raise StopAsyncIteration
        return message

    async def send(self, payload):
        if isinstance(payload, bytes):
            self.client.publish(self.topics["down_audio"], payload, qos=self.audio_qos)
        else:
            self.client.publish(self.topics["down_json"], payload, qos=self.json_qos)

    async def close(self):
        if not self.closed:
            self.closed = True
            await self._incoming.put(_CLOSE_SENTINEL)

    async def receive_json(self, payload: str):
        await self._incoming.put(payload)

    async def receive_audio(self, payload: bytes):
        await self._incoming.put(payload)
