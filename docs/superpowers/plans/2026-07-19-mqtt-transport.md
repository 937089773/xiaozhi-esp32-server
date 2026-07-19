# MQTT Transport Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new MQTT/TLS transport between ESP32 clients and `xiaozhi-server` through EMQX Cloud without deleting existing transports.

**Architecture:** The server starts an optional MQTT transport alongside the existing WebSocket server. The ESP32 client gets a new `MqttTransportProtocol` selected by a new Kconfig connection type. JSON and Opus audio are carried on separate per-device MQTT topics.

**Tech Stack:** Python asyncio, paho-mqtt for server MQTT, ESP-IDF C++, existing ESP32 `Mqtt` abstraction, EMQX Cloud MQTT/TLS.

## Global Constraints

- Do not push to a remote.
- Local git commits are allowed.
- Do not delete WebSocket code, existing MQTT+UDP code, WebSocket server code, or MQTT gateway compatibility code.
- Use MQTT/TLS on port 8883, not MQTT over WebSocket.
- MQTT settings are written during ESP32 flashing/provisioning; runtime OTA config is not required for the new transport.

---

### Task 1: Server MQTT Topic And Connection Adapter

**Files:**
- Create: `main/xiaozhi-server/core/transports/__init__.py`
- Create: `main/xiaozhi-server/core/transports/mqtt_connection.py`
- Test: `main/xiaozhi-server/test/test_mqtt_transport_connection.py`

**Interfaces:**
- Produces: `MqttTransportConnection(device_id: str, client, topic_prefix: str, json_qos: int = 1, audio_qos: int = 0)`
- Produces: `MqttTransportConnection.send(payload) -> awaitable`
- Produces: `MqttTransportConnection.close() -> awaitable`
- Produces: `build_device_topics(topic_prefix: str, device_id: str) -> dict[str, str]`

- [ ] Write failing tests for topic generation and `send(str)`/`send(bytes)` publish routing.
- [ ] Run `python -m pytest test/test_mqtt_transport_connection.py -q` from `main/xiaozhi-server`; expect import failure.
- [ ] Implement `mqtt_connection.py` with the minimal adapter and fake WebSocket request attributes.
- [ ] Re-run the test and confirm it passes.

### Task 2: Server MQTT Transport Listener

**Files:**
- Create: `main/xiaozhi-server/core/transports/mqtt_transport.py`
- Modify: `main/xiaozhi-server/requirements.txt`
- Test: `main/xiaozhi-server/test/test_mqtt_transport.py`

**Interfaces:**
- Consumes: `MqttTransportConnection`, `build_device_topics`
- Produces: `MqttTransport(config: dict, connection_factory=None)`
- Produces: `MqttTransport.extract_device_id(topic: str) -> str | None`
- Produces: `MqttTransport.handle_message(topic: str, payload: bytes) -> None`

- [ ] Write failing tests for device ID extraction and routing `up/json`/`up/audio` to a connection object.
- [ ] Run `python -m pytest test/test_mqtt_transport.py -q`; expect import failure.
- [ ] Add `paho-mqtt` to requirements if missing.
- [ ] Implement listener scaffolding with start/stop methods and message routing.
- [ ] Re-run server MQTT tests and confirm they pass.

### Task 3: Server Startup Integration

**Files:**
- Modify: `main/xiaozhi-server/app.py`
- Modify: `main/xiaozhi-server/config.yaml`

**Interfaces:**
- Consumes: `MqttTransport.start()` and `MqttTransport.stop()`

- [ ] Add `mqtt_transport` config defaults with `enabled: false`.
- [ ] Start MQTT transport only when `mqtt_transport.enabled` is true.
- [ ] Keep existing WebSocket startup unchanged.
- [ ] Run import/compile checks for `app.py`.

### Task 4: ESP32 MQTT Transport Protocol

**Files:**
- Create: `main/protocols/mqtt_transport_protocol.h`
- Create: `main/protocols/mqtt_transport_protocol.cc`
- Modify: `main/protocols/CMakeLists.txt` if protocol sources are listed separately.

**Interfaces:**
- Produces: `class MqttTransportProtocol : public Protocol`

- [ ] Copy only the reusable MQTT connection shape from existing `MqttProtocol`.
- [ ] Implement MQTT/TLS connect using `Settings("mqtt_transport", false)`.
- [ ] Subscribe to `{topic_prefix}/down/json` and `{topic_prefix}/down/audio`.
- [ ] Publish JSON to `{topic_prefix}/up/json` and audio to `{topic_prefix}/up/audio`.
- [ ] Use `transport: "mqtt"` in hello and accept only server hello with `transport: "mqtt"`.
- [ ] Do not create or reference UDP in the new protocol.

### Task 5: ESP32 Compile-Time Selection

**Files:**
- Modify: `main/application.cc`
- Modify: `main/Kconfig.projbuild`
- Modify: `main/CMakeLists.txt` if needed

**Interfaces:**
- Consumes: `MqttTransportProtocol`

- [ ] Add `CONFIG_CONNECTION_TYPE_MQTT_TRANSPORT` as a third connection option.
- [ ] Include `mqtt_transport_protocol.h` in `application.cc`.
- [ ] Select `MqttTransportProtocol` only when the new option is enabled.
- [ ] Preserve existing WebSocket and MQTT+UDP selection behavior.

### Task 6: Verification And Commits

**Files:**
- All changed files

- [ ] Run server targeted tests.
- [ ] Run Python compile checks for changed server modules.
- [ ] Run ESP32 build/config verification available in the workspace.
- [ ] Inspect `git diff` in both repositories.
- [ ] Commit server changes locally.
- [ ] Commit ESP32 client changes locally.
- [ ] Do not push.
