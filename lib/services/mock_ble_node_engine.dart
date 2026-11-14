import 'dart:async';
import 'dart:typed_data';
import '../protocol/ble_packet_codec.dart';
import 'ble_service.dart';

/// In-Memory Mock BLE Relay Engine for headless simulation & automated testing.
class MockBleNodeEngine implements BleHardwareBridge {
  BleConnectionState _state = BleConnectionState.disconnected;
  String? _connectedNodeName;
  int _rssi = -88;
  final int _pingLatencyMs = 18;

  final List<Uint8List> transmittedFrames = [];
  final List<BlePacket> transmittedPackets = [];
  bool autoRespondPresence = true;

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

    _connectedNodeName = nodeIdOrAddress;
    _rssi = -62;
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
  Future<void> setHighPriorityConnection(bool high) async {}

  @override
  Future<bool> sendPacket(Uint8List frameBytes) async {
    if (_state != BleConnectionState.connected) return false;
    transmittedFrames.add(frameBytes);
    try {
      final pkt = BlePacketCodec.decode(frameBytes);
      transmittedPackets.add(pkt);

      if (autoRespondPresence && pkt.isPresence) {
        final ack = BlePacketCodec.encode(
          BlePacket(
            messageId: pkt.messageId,
            payloadTypeFlag: BlePayloadFlag.presenceHello,
            senderId: 'RELAY',
            targetId: pkt.senderId,
            payload: Uint8List.fromList([0x01]),
          ),
        );
        scheduleMicrotask(() {
          if (!_packetRxController.isClosed) {
            _packetRxController.add(BlePacketCodec.decode(ack));
          }
        });
      }
    } catch (_) {}
    return true;
  }

  @override
  Future<bool> sendUrgentPacket(Uint8List frameBytes) => sendPacket(frameBytes);

  @override
  Future<bool> sendReliablePacket(Uint8List frameBytes) => sendPacket(frameBytes);

  void simulateIncomingCallAudio({
    required String callId,
    required String senderId,
    required String targetId,
    int seqNum = 1,
    int predictor = 0,
    int stepIndex = 0,
    Uint8List? adpcmBytes,
  }) {
    final frame = BlePacketCodec.encodeCallAudio(
      callId: callId,
      senderId: senderId,
      targetId: targetId,
      seqNum: seqNum,
      predictor: predictor,
      stepIndex: stepIndex,
      frameMs: 40,
      adpcmBytes: adpcmBytes ?? Uint8List.fromList(List.filled(160, 0x33)),
    );
    _packetRxController.add(BlePacketCodec.decode(frame));
  }

  void simulateIncomingText({
    required String messageId,
    required String senderId,
    required String targetId,
    required String text,
    bool isGroup = false,
  }) {
    final frame = BlePacketCodec.encodeText(
      messageId: messageId,
      senderId: senderId,
      targetId: targetId,
      text: text,
      isGroup: isGroup,
    );
    _packetRxController.add(BlePacketCodec.decode(frame));
  }

  void simulateIncomingVoice({
    required String messageId,
    required String senderId,
    required String targetId,
    required Uint8List audioBlob,
    int durationMs = 2000,
    int codecType = VoiceCodecType.wavPcm,
    bool isGroup = false,
  }) {
    final frames = BlePacketCodec.encodeVoiceChunks(
      messageId: messageId,
      senderId: senderId,
      targetId: targetId,
      audioBlob: audioBlob,
      durationMs: durationMs,
      codecType: codecType,
      isGroup: isGroup,
    );
    for (final f in frames) {
      _packetRxController.add(BlePacketCodec.decode(f));
    }
  }

  void simulateIncomingAck({
    required String messageId,
    required String senderId,
    required String targetId,
    bool isDelivered = true,
  }) {
    final frame = BlePacketCodec.encodeAck(
      messageId: messageId,
      senderId: senderId,
      targetId: targetId,
      statusCode: isDelivered ? 0x01 : 0x02,
    );
    _packetRxController.add(BlePacketCodec.decode(frame));
  }

  void simulateCallSignal({
    required String callId,
    required String senderId,
    required String targetId,
    required int signalCode,
  }) {
    final frame = BlePacketCodec.encodeCallSignal(
      callId: callId,
      senderId: senderId,
      targetId: targetId,
      signalCode: signalCode,
    );
    _packetRxController.add(BlePacketCodec.decode(frame));
  }

  void simulatePeerDirectory(List<DirectoryPeerEntry> entries) {
    final builder = BytesBuilder();
    builder.addByte(0); // page
    builder.addByte(1); // totalPages
    builder.addByte(entries.length);
    for (final e in entries) {
      final ub = e.username.codeUnits;
      final db = e.displayName.codeUnits;
      builder.addByte(ub.length);
      builder.add(ub);
      builder.addByte(db.length);
      builder.add(db);
      builder.addByte(e.isOnline ? 1 : 0);
    }
    final frame = BlePacketCodec.encode(
      BlePacket(
        messageId: '00000000-0000-0000-0000-000000000000',
        payloadTypeFlag: BlePayloadFlag.peerDirectory,
        senderId: 'RELAY',
        targetId: 'ALL',
        payload: builder.toBytes(),
      ),
    );
    _packetRxController.add(BlePacketCodec.decode(frame));
  }

  void simulatePresenceConflict(String targetId) {
    final frame = BlePacketCodec.encode(
      BlePacket(
        messageId: '00000000-0000-0000-0000-000000000000',
        payloadTypeFlag: BlePayloadFlag.presenceHello,
        senderId: 'RELAY',
        targetId: targetId,
        payload: Uint8List.fromList([0x02]),
      ),
    );
    _packetRxController.add(BlePacketCodec.decode(frame));
  }

  void clearTransmittedLogs() {
    transmittedFrames.clear();
    transmittedPackets.clear();
  }

  @override
  void dispose() {
    _stateController.close();
    _packetRxController.close();
  }
}
