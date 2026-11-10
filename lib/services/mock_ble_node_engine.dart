import 'dart:async';
import 'dart:typed_data';
import '../protocol/ble_packet_codec.dart';
import 'ble_service.dart';

/// In-Memory Mock BLE Engine simulating Heltec WiFi LoRa 32 V3 node interactions:
/// - Simulates Phone Out-of-Range (Disconnected).
/// - Simulates Connecting to Node [P1..P6/C] with realistic RSSI & Ping Latency.
/// - Captures TX packets sent by Phone to verify framing & byte sizes.
/// - Pushes RX incoming buffered message packets and delivery ACKs.
class MockBleNodeEngine implements BleHardwareBridge {
  BleConnectionState _state = BleConnectionState.disconnected;
  String? _connectedNodeName;
  int _rssi = -88;
  int _pingLatencyMs = 18;

  final List<Uint8List> transmittedFrames = [];
  final List<BlePacket> transmittedPackets = [];

  final StreamController<BleConnectionState> _stateController =
      StreamController<BleConnectionState>.broadcast();
  final StreamController<BlePacket> _packetRxController =
      StreamController<BlePacket>.broadcast();

  @override
  BleConnectionState get state => _state;
  @override
  String? get connectedNodeName => _connectedNodeName;
  @override
  int get rssi => _rssi;
  @override
  int get pingLatencyMs => _pingLatencyMs;
  @override
  Stream<BleConnectionState> get stateStream => _stateController.stream;
  @override
  Stream<BlePacket> get packetRxStream => _packetRxController.stream;

  void setRssi(int newRssi) {
    _rssi = newRssi;
  }

  void setPingLatency(int ms) {
    _pingLatencyMs = ms;
  }

  @override
  Future<void> startScan() async {
    _state = BleConnectionState.scanning;
    _stateController.add(_state);
  }

  @override
  Future<void> stopScan() async {
    if (_state == BleConnectionState.scanning) {
      _state = BleConnectionState.disconnected;
      _stateController.add(_state);
    }
  }

  @override
  Future<bool> connectToNode(String nodeIdOrAddress) async {
    _state = BleConnectionState.connecting;
    _stateController.add(_state);

    await Future.microtask(() {});

    _connectedNodeName = nodeIdOrAddress.startsWith('NODE-')
        ? nodeIdOrAddress
        : 'NODE-$nodeIdOrAddress';
    _rssi = -64;
    _pingLatencyMs = 21;
    _state = BleConnectionState.connected;
    _stateController.add(_state);
    return true;
  }

  @override
  Future<void> disconnect() async {
    _state = BleConnectionState.disconnected;
    _connectedNodeName = null;
    _stateController.add(_state);
  }

  @override
  Future<bool> sendPacket(Uint8List frameBytes) async {
    if (_state != BleConnectionState.connected) {
      return false;
    }
    transmittedFrames.add(frameBytes);
    try {
      final packet = BlePacketCodec.decode(frameBytes);
      transmittedPackets.add(packet);
    } catch (_) {}
    return true;
  }

  /// Simulation Trigger: Simulates an incoming text message delivered from the LoRa mesh.
  void simulateIncomingText({
    required String messageId,
    required String senderNodeId,
    required String text,
  }) {
    final frame = BlePacketCodec.encodeText(
      messageId: messageId,
      recipientId: senderNodeId,
      text: text,
    );
    final packet = BlePacketCodec.decode(frame);
    _packetRxController.add(packet);
  }

  /// Simulation Trigger: Simulates an incoming voice note delivered from the LoRa mesh.
  void simulateIncomingVoice({
    required String messageId,
    required String senderNodeId,
    required Uint8List audioBlob,
  }) {
    final frame = BlePacketCodec.encodeVoice(
      messageId: messageId,
      recipientId: senderNodeId,
      audioBlob: audioBlob,
    );
    final packet = BlePacketCodec.decode(frame);
    _packetRxController.add(packet);
  }

  /// Simulation Trigger: Simulates an end-to-end LoRa delivery ACK from recipient node.
  void simulateIncomingAck({
    required String messageId,
    required String recipientId,
    bool isDelivered = true,
  }) {
    final frame = BlePacketCodec.encodeAck(
      messageId: messageId,
      recipientId: recipientId,
      statusCode: isDelivered ? 0x01 : 0x02,
    );
    final packet = BlePacketCodec.decode(frame);
    _packetRxController.add(packet);
  }

  /// Clears recorded transmission logs.
  void clearTransmittedLogs() {
    transmittedFrames.clear;
    transmittedPackets.clear();
  }

  @override
  void dispose() {
    _stateController.close();
    _packetRxController.close();
  }
}

