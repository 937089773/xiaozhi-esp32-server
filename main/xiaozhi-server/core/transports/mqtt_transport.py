import asyncio
import contextlib
from typing import Callable

from core.transports.mqtt_connection import MqttTransportConnection


TAG = __name__


class MqttTransport:
    def __init__(self, config: dict, connection_factory: Callable[[str], object] | None = None, app_config: dict | None = None, server=None):
        self.transport_config = config
        self.app_config = app_config
        self.server = server
        self.topic_prefix = config.get("topic_prefix", "xiaozhi/device").rstrip("/")
        self.json_qos = int(config.get("qos", {}).get("json", 1))
        self.audio_qos = int(config.get("qos", {}).get("audio", 0))
        self.connection_factory = connection_factory
        self.connections = {}
        self.client = None
        self.logger = None
        self.loop = None
        self._watchdog_task = None

    def extract_device_id(self, topic: str) -> str | None:
        prefix = f"{self.topic_prefix}/"
        if not topic.startswith(prefix):
            return None
        suffix = topic[len(prefix):]
        parts = suffix.split("/")
        if len(parts) != 3 or parts[1] != "up" or parts[2] not in ("json", "audio"):
            return None
        return parts[0]

    async def handle_message(self, topic: str, payload: bytes):
        device_id = self.extract_device_id(topic)
        if device_id is None:
            return

        conn = self._get_connection(device_id)
        if topic.endswith("/up/json"):
            message = payload.decode("utf-8") if isinstance(payload, bytes) else payload
            if hasattr(conn, "receive_json"):
                await conn.receive_json(message)
            return

        if hasattr(conn, "receive_audio"):
            await conn.receive_audio(payload)

    async def start(self):
        import paho.mqtt.client as mqtt

        self.loop = asyncio.get_running_loop()
        self.client = mqtt.Client(client_id=self.transport_config.get("client_id", "xiaozhi-server"))
        username = self.transport_config.get("username")
        password = self.transport_config.get("password")
        if username:
            self.client.username_pw_set(username, password)
        if self.transport_config.get("tls", True):
            self.client.tls_set()

        self.client.on_connect = self._on_connect
        self.client.on_disconnect = self._on_disconnect
        self.client.on_message = self._on_message
        self.client.connect(self.transport_config["endpoint"], int(self.transport_config.get("port", 8883)), keepalive=60)
        self.client.loop_start()
        self._watchdog_task = asyncio.create_task(self._watch_mqtt_connection())
        self._logger().bind(tag=TAG).info("MQTT transport started")

    async def stop(self):
        if self._watchdog_task is not None:
            self._watchdog_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._watchdog_task
            self._watchdog_task = None
        if self.client is not None:
            self.client.loop_stop()
            self.client.disconnect()
            self.client = None

    def _get_connection(self, device_id: str):
        if device_id in self.connections and getattr(self.connections[device_id], "closed", False):
            del self.connections[device_id]
        if device_id not in self.connections:
            if self.connection_factory is not None:
                self.connections[device_id] = self.connection_factory(device_id)
            else:
                self.connections[device_id] = MqttTransportConnection(
                    device_id,
                    self.client,
                    self.topic_prefix,
                    json_qos=self.json_qos,
                    audio_qos=self.audio_qos,
                )
                if self.app_config is not None:
                    if self.loop is not None:
                        self.loop.create_task(self._handle_connection(self.connections[device_id]))
                    else:
                        asyncio.create_task(self._handle_connection(self.connections[device_id]))
        return self.connections[device_id]

    async def _handle_connection(self, websocket):
        from core.connection import ConnectionHandler

        handler = ConnectionHandler(
            self.app_config,
            getattr(self.server, "_vad", None),
            getattr(self.server, "_asr", None),
            getattr(self.server, "_llm", None),
            getattr(self.server, "_memory", None),
            getattr(self.server, "_intent", None),
            self.server,
        )
        await handler.handle_connection(websocket)

    def _on_connect(self, client, userdata, flags, reason_code, properties=None):
        self._logger().bind(tag=TAG).info("MQTT transport connected: {}", reason_code)
        self._subscribe_topics(client)

    def _on_disconnect(self, client, userdata, *args):
        reason_code = args[-2] if len(args) >= 2 else (args[0] if args else None)
        self._logger().bind(tag=TAG).warning("MQTT transport disconnected: {}", reason_code)

    def _on_message(self, client, userdata, message):
        if message.topic.endswith("/up/json"):
            self._logger().bind(tag=TAG).info(
                "MQTT transport received json topic={}, bytes={}",
                message.topic,
                len(message.payload),
            )
        elif message.topic.endswith("/up/audio"):
            self._logger().bind(tag=TAG).debug(
                "MQTT transport received audio topic={}, bytes={}",
                message.topic,
                len(message.payload),
            )
        if self.loop is not None:
            self.loop.call_soon_threadsafe(
                lambda: self.loop.create_task(self.handle_message(message.topic, message.payload))
            )
        else:
            asyncio.run(self.handle_message(message.topic, message.payload))

    def _subscribe_topics(self, client):
        topics = (
            (f"{self.topic_prefix}/+/up/json", self.json_qos),
            (f"{self.topic_prefix}/+/up/audio", self.audio_qos),
            (f"{self.topic_prefix}/+/status", self.json_qos),
        )
        for topic, qos in topics:
            result = client.subscribe(topic, qos=qos)
            self._logger().bind(tag=TAG).info(
                "MQTT transport subscribe requested: topic={}, qos={}, result={}",
                topic,
                qos,
                result,
            )

    async def _watch_mqtt_connection(self):
        interval = int(self.transport_config.get("watchdog_interval", 30))
        while True:
            await asyncio.sleep(interval)
            client = self.client
            if client is None:
                return
            is_connected = getattr(client, "is_connected", lambda: True)()
            if not is_connected:
                self._logger().bind(tag=TAG).warning("MQTT transport watchdog reconnecting")
                with contextlib.suppress(Exception):
                    client.reconnect()
                continue
            self._subscribe_topics(client)

    def _logger(self):
        if self.logger is None:
            from config.logger import setup_logging
            self.logger = setup_logging()
        return self.logger
