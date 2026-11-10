# 📡 Off-Grid Decentralized Message Mail - Development Handover

## 1. System Goal & Overview
This project is an **Off-Grid, Decentralized Communication System** designed to operate without cellular networks, internet connections, or centralized cloud servers.

### Architecture
1. **Physical Relay Layer (ESP32 / Heltec LoRa)**:
   - Operates as a store-and-forward relay node and local BLE GATT server.
   - Buffers incoming packets in RAM and broadcasts them in real-time or asynchronously to in-range clients.
2. **Mobile Client Layer (Flutter Android App)**:
   - **Autonomous Radar Auto-Connect**: Zero-touch background radar continuously sweeps for nearby relay nodes and connects automatically without requiring manual Bluetooth pairing or connection menus.
   - **Offline Store-and-Forward (SQLite)**: Messages composed out-of-range are saved to local SQLite (`PENDING_LOCAL`).
   - **Automatic Queue Flushing**: As soon as the phone enters radar range of the ESP32, it connects and automatically flushes the outbox to the relay.
   - **Real-Time P2P Chat**: When both sender and receiver are connected to the relay simultaneously, messages are relayed immediately with live delivery acknowledgments (`DELIVERED`).

---

## 2. Firmware Structure & Differences

In the `firmware/` directory:

| Sketch | Target Hardware | Purpose |
|---|---|---|
| `firmware/esp32_devkit_v1_relay/esp32_devkit_v1_relay.ino` | **DOIT ESP32 DevKit V1** (ESP-WROOM-32) | **Primary Active Sketch**. Includes onboard blue LED indicators, multi-client BLE advertising, real-time message notification, and RAM mailbox store-and-forward. |
| `firmware/esp32_relay_node/esp32_relay_node.ino` | Generic ESP32 (WROOM/WROVER) | Headless baseline relay sketch without specific board LED assignments. |
| `firmware/heltec_lora_mesh/heltec_lora_mesh.ino` | Heltec WiFi LoRa 32 V3 (ESP32-S3 + SX1262) | Extends BLE relay over long-distance Sub-GHz (915 MHz) LoRa mesh radio. |

---

## 3. Work Completed

### A. ESP32 Arduino Core 3.0+ Compilation Fix
- Fixed compilation error: `conversion from 'String' to non-scalar type 'std::string' requested` caused by API updates in ESP32 Core 3.x.
- Replaced `std::string` with Arduino `String` and used `.c_str()` for raw byte pointer casting.
- Synchronized across repository firmware and Arduino IDE temp sketch.

### B. Zero-Touch Autonomous Bluetooth Radar
- **File**: `lib/services/ble_service.dart` (`FlutterBluePlusBridge`)
- Built an automatic scanning and reconnection state machine.
- Scans openly for `serviceUuid` (`0000a101-0000-1000-8000-00805f9b34fb`) or advertised names containing `ESP32`, `DEVKIT`, `RELAY`, or `NODE`.
- Automatic link health monitoring: detects disconnection instantly and restarts radar search after a 2-second cooldown.
- Periodic RSSI telemetry polling (every 5 seconds) to track physical signal strength.

### C. Real-Time Chat & End-to-End ACK Delivery
- **Files**: `lib/services/ble_service.dart`, `firmware/esp32_devkit_v1_relay/esp32_devkit_v1_relay.ino`, `lib/protocol/ble_packet_codec.dart`
- Multi-client BLE advertising: ESP32 restarts advertising in `onConnect` so multiple phones can connect at once.
- Real-time forwarding: When a phone sends a frame, ESP32 notifies all connected GATT clients immediately.
- Mailbox SYNC Protocol (Flag `0x04`): When a phone connects, it transmits a `SYNC_POLL` frame to pull any buffered messages stored during its absence.
- End-to-End Delivery ACK (Flag `0x03`): Recipient phone returns an ACK upon receiving a message, transitioning the sender's message from `IN_TRANSIT` to `DELIVERED` (double checkmark).

### D. Dual Node Identity Switcher in UI
- **Files**: `lib/screens/home_screen.dart`, `lib/providers/message_mail_provider.dart`
- Added an identity selector to the App Bar:
  ```text
  [ME: P1 ▾] ➜ [TO: P2 ▾]
  ```
- Allows two physical phones to easily swap between `NODE-P1` and `NODE-P2` without hardcoded ID collisions.

### E. Live Connection Status Pill
- **File**: `lib/widgets/connection_status_pill.dart`
- Three-state dynamic visual header:
  - 🟢 **ONLINE**: Connected to relay, live RSSI and ping latency.
  - 🔵 **RADAR ACTIVE**: Sweeping perimeter for relay node.
  - 🔴 **OFFLINE**: Disconnected, offline cache active, queue counter displayed.

### F. Verification & Release Build
- All 22 automated tests passing (`flutter test`):
  - Protocol framing & binary encoding tests
  - SQLite persistence & queue lifecycle tests
  - Autonomous radar simulation tests
  - UI component widget tests
- Successfully compiled the release APK:
  - **Path**: `build/app/outputs/flutter-apk/app-release.apk`
  - **Size**: ~47.0 MB (49,318,230 bytes)

---

## 4. How to Continue from Another Machine

1. **Clone / Pull the repository**:
   ```powershell
   git pull origin main
   ```
2. **Fetch Flutter packages**:
   ```powershell
   flutter pub get
   ```
3. **Run tests**:
   ```powershell
   flutter test
   ```
4. **Deploy the firmware**:
   - Open `firmware/esp32_devkit_v1_relay/esp32_devkit_v1_relay.ino` in Arduino IDE.
   - Select Board: **DOIT ESP32 DEVKIT V1**.
   - Upload to your ESP32 board.
5. **Install the Mobile App**:
   - Connect phone via USB (with Developer Mode & USB Debugging ON):
     ```powershell
     adb install -r build/app/outputs/flutter-apk/app-release.apk
     ```
   - On Phone 1 set: `ME: P1` ➜ `TO: P2`
   - On Phone 2 set: `ME: P2` ➜ `TO: P1`

