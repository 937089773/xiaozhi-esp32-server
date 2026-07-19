# MQTT Transport Design

## Scope

Add a new pure MQTT/TLS transport between `xiaozhi-esp32` and `xiaozhi-esp32-server` through EMQX Cloud.

This design does not remove or rewrite existing transports. WebSocket, existing MQTT+UDP client code, WebSocket server code, and MQTT gateway compatibility remain available.

## Goals

- Let ESP32 devices and `xiaozhi-server` communicate through EMQX Cloud only.
- Use MQTT/TLS on port 8883, not MQTT over WebSocket.
- Carry JSON control messages and Opus audio frames over MQTT topics.
- Avoid network tunneling and avoid requiring the remote intranet server to accept inbound public traffic.
- Add a new transport mode instead of changing the behavior of existing modes.

## Non-Goals

- Do not delete `websocket_protocol.*` from the ESP32 client.
- Do not delete the current `mqtt_protocol.*` MQTT+UDP implementation from the ESP32 client.
- Do not delete `websocket_server.py` from the server.
- Do not remove `conn_from_mqtt_gateway` compatibility code.
- Do not introduce MQTT over WebSocket for ESP32.
- Do not require OTA to provide MQTT connection settings at runtime.

## Architecture

Both sides connect outward to the same EMQX Cloud broker.

```text
xiaozhi-esp32
  MQTT/TLS client
    |
    v
EMQX Cloud
    ^
    |
xiaozhi-server
  MQTT/TLS client
```

The ESP32 publishes upstream JSON and audio topics. The server subscribes to upstream topics and publishes downstream JSON and audio topics. The ESP32 subscribes to its own downstream topics.

## Topic Layout

Use one topic namespace per device.

```text
xiaozhi/device/{device_id}/up/json
xiaozhi/device/{device_id}/up/audio
xiaozhi/device/{device_id}/down/json
xiaozhi/device/{device_id}/down/audio
xiaozhi/device/{device_id}/status
```

ESP32:

```text
publish   xiaozhi/device/{device_id}/up/json
publish   xiaozhi/device/{device_id}/up/audio
publish   xiaozhi/device/{device_id}/status
subscribe xiaozhi/device/{device_id}/down/json
subscribe xiaozhi/device/{device_id}/down/audio
```

Server:

```text
subscribe xiaozhi/device/+/up/json
subscribe xiaozhi/device/+/up/audio
subscribe xiaozhi/device/+/status
publish   xiaozhi/device/{device_id}/down/json
publish   xiaozhi/device/{device_id}/down/audio
```

QoS:

```text
json  QoS 1
audio QoS 0
```

Control messages need delivery reliability. Audio needs low latency and should not backlog if the network stalls.

## ESP32 Client Design

Add a new protocol implementation in the client project:

```text
main/protocols/mqtt_transport_protocol.h
main/protocols/mqtt_transport_protocol.cc
```

The new implementation implements the existing `Protocol` interface.

Behavior:

- `Start()` connects to EMQX Cloud with MQTT/TLS and subscribes to downstream JSON/audio topics.
- `OpenAudioChannel()` publishes a `hello` JSON message to `up/json` and waits for server `hello` on `down/json`.
- `SendText()` publishes JSON payloads to `up/json`.
- `SendAudio()` publishes binary audio payloads to `up/audio`.
- `CloseAudioChannel()` publishes `goodbye` to `up/json` and marks the channel closed.
- `IsAudioChannelOpened()` returns true only when MQTT is connected, server hello was received, no protocol error occurred, and the connection has not timed out.
- The MQTT message callback dispatches by topic: `down/json` is parsed as JSON and `down/audio` is delivered as incoming audio.

Add a new compile-time connection type:

```text
CONFIG_CONNECTION_TYPE_MQTT_TRANSPORT
```

Protocol selection becomes three-way:

```cpp
#ifdef CONFIG_CONNECTION_TYPE_WEBSOCKET
    protocol_ = std::make_unique<WebsocketProtocol>();
#elif defined(CONFIG_CONNECTION_TYPE_MQTT_TRANSPORT)
    protocol_ = std::make_unique<MqttTransportProtocol>();
#else
    protocol_ = std::make_unique<MqttProtocol>();
#endif
```

The existing `MqttProtocol` remains the current MQTT+UDP implementation.

### ESP32 Configuration

MQTT settings are written when flashing/provisioning the ESP32. Runtime OTA configuration is not required for the new transport.

Required settings:

```text
endpoint
port
client_id
username
password
topic_prefix
```

Example:

```text
endpoint=xxx.emqxsl.com
port=8883
client_id=xiaozhi-device-001
username=device-001
password=device-password
topic_prefix=xiaozhi/device/device-001
```

The client derives concrete topics from `topic_prefix`.

## Server Design

Add a new MQTT transport to the server project. Prefer a transport-specific module instead of changing the WebSocket server.

Suggested files:

```text
main/xiaozhi-server/core/transports/mqtt_transport.py
main/xiaozhi-server/core/transports/mqtt_connection.py
```

If a new `transports` package is too invasive, use:

```text
main/xiaozhi-server/core/mqtt_transport_server.py
main/xiaozhi-server/core/mqtt_transport_connection.py
```

Server startup:

- Keep starting `WebSocketServer` as today.
- If `mqtt_transport.enabled` is true, also start the MQTT transport.
- MQTT transport connects to EMQX Cloud and subscribes to upstream wildcard topics.
- When a device sends `hello`, create or reuse a per-device MQTT connection/session.

The first implementation should adapt to the existing `ConnectionHandler` rather than rewriting ASR, TTS, LLM, IoT, and memory logic.

`MqttTransportConnection` provides the minimum interface currently expected from WebSocket-like code:

```text
send(payload)
close()
request.headers
request.path
remote_address
```

Routing rules:

- `send(str)` publishes to `down/json` with QoS 1.
- `send(bytes)` publishes to `down/audio` with QoS 0.
- Incoming `up/json` is routed into the existing text JSON handling path.
- Incoming `up/audio` is routed into the existing audio handling path.

## Server Configuration

Add configuration under `main/xiaozhi-server/config.yaml` or the existing runtime config mechanism:

```yaml
mqtt_transport:
  enabled: true
  endpoint: "xxx.emqxsl.com"
  port: 8883
  username: "server-user"
  password: "server-password"
  client_id: "xiaozhi-server"
  topic_prefix: "xiaozhi/device"
  tls: true
  qos:
    json: 1
    audio: 0
```

Secrets may be supplied through the existing deployment configuration approach if that project already supports environment-specific config overrides.

## JSON Protocol

The new transport keeps existing JSON message types where possible.

ESP32 hello:

```json
{
  "type": "hello",
  "version": 1,
  "transport": "mqtt",
  "audio_params": {
    "format": "opus",
    "sample_rate": 16000,
    "channels": 1,
    "frame_duration": 60
  }
}
```

Server hello:

```json
{
  "type": "hello",
  "version": 1,
  "transport": "mqtt",
  "session_id": "server-generated-session-id",
  "audio_params": {
    "format": "opus",
    "sample_rate": 24000,
    "channels": 1,
    "frame_duration": 60
  }
}
```

`goodbye`, `listen`, `abort`, IoT descriptors, IoT states, TTS state, STT result, and LLM text messages continue using the existing JSON payload shapes unless a concrete incompatibility is found during implementation.

## Audio Protocol

MQTT audio payloads are binary.

Use the existing MQTT gateway audio packet shape to reduce server-side changes:

```text
16-byte header + opus payload
```

Header:

```text
byte 0      type, 1 = audio
byte 1      flags/reserved
byte 2-3    payload length, uint16 big-endian
byte 4-7    sequence, uint32 big-endian
byte 8-11   timestamp, uint32 big-endian
byte 12-15  opus length, uint32 big-endian
byte 16..   opus data
```

Client upload and server download both use the same packet shape.

The ESP32 can pass decoded Opus payloads to the existing playback queue after stripping the header, or the client implementation can deliver only the Opus payload to `on_incoming_audio_` after validation. The latter keeps the rest of the client unchanged.

## Authentication And ACL

Use separate EMQX credentials for devices and server.

Device ACL:

```text
allow publish   xiaozhi/device/{device_id}/up/#
allow subscribe xiaozhi/device/{device_id}/down/#
deny   publish   xiaozhi/device/+/down/#
deny   subscribe xiaozhi/device/+/up/#
```

Server ACL:

```text
allow subscribe xiaozhi/device/+/up/#
allow publish   xiaozhi/device/+/down/#
```

Each ESP32 should have a distinct `client_id`. Prefer per-device username/password when operationally feasible.

## Error Handling

Client:

- If MQTT connect fails, report server connection error through `SetError()`.
- If server hello is not received within the existing timeout window, report timeout.
- If `down/json` contains invalid JSON, log and ignore that message.
- If `down/audio` has an invalid header or stale sequence, log and ignore that packet.
- On MQTT disconnect, mark the audio channel closed and allow reconnect on the next `OpenAudioChannel()`.

Server:

- If MQTT connect fails at startup, log a clear error and keep WebSocket mode available.
- If one device sends malformed JSON, close or reset only that device session.
- If audio arrives before hello/session setup, drop it and log at debug or warning level.
- If a device reconnects with the same device ID, close the previous MQTT session object before creating the new one.

## Testing Plan

Unit-level checks:

- Topic parsing maps `{device_id}` correctly.
- `MqttTransportConnection.send(str)` publishes to `down/json`.
- `MqttTransportConnection.send(bytes)` publishes to `down/audio`.
- Audio header encode/decode validates payload length and sequence.

Integration checks with EMQX:

- Server connects to EMQX and subscribes to upstream wildcard topics.
- A simulated ESP32 publishes `hello`; server responds with `hello` on the device downstream JSON topic.
- A simulated ESP32 sends `listen` and `goodbye`; server routes them through the existing handlers.
- A simulated ESP32 sends one Opus audio packet; server accepts it without WebSocket or UDP.
- Server publishes one downstream audio packet; a simulated ESP32 subscriber receives it.

Device checks:

- ESP32 connects to EMQX over MQTT/TLS.
- ESP32 subscribes to downstream topics.
- ESP32 opens an audio channel after server hello.
- ESP32 sends and receives audio without creating a UDP socket.

## Implementation Order

1. Add the server MQTT transport connection and topic routing with mocked publish tests.
2. Start MQTT transport from `app.py` behind `mqtt_transport.enabled`.
3. Route upstream JSON through the existing server message handling path.
4. Route downstream JSON through MQTT publish.
5. Add ESP32 `MqttTransportProtocol` with MQTT connect, subscribe, JSON hello, and JSON receive.
6. Add ESP32 compile-time selection for `CONFIG_CONNECTION_TYPE_MQTT_TRANSPORT`.
7. Add MQTT binary audio publish/subscribe on ESP32.
8. Add server upstream/downstream audio routing.
9. Test with EMQX Cloud using one simulated device, then one real ESP32.

## Open Implementation Checks

- Confirm the ESP32 `Mqtt` abstraction supports MQTT/TLS port 8883 with the EMQX Cloud certificate requirements.
- Confirm the ESP32 `Mqtt` abstraction supports binary publish and binary subscribe payloads without truncation at null bytes.
- Confirm EMQX Cloud message size and rate limits are compatible with the selected Opus frame duration.
- Confirm the existing server runtime already includes an MQTT client library or add one deliberately.

These are implementation checks, not unresolved product requirements. If a check fails, keep the transport design and adjust only the affected adapter or MQTT client implementation.
