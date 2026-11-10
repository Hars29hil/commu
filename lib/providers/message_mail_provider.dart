import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/message_mail.dart';
import '../services/audio_service.dart';
import '../services/ble_service.dart';
import '../services/database_service.dart';
import '../services/mock_ble_node_engine.dart';

class MessageMailProvider extends ChangeNotifier {
  final DatabaseService db;
  final AudioService audio;
  final Uuid _uuid = const Uuid();

  late BleHardwareBridge _bridge;
  late BleSyncCoordinator _coordinator;
  bool _isUsingMock = true; // Defaults to mock engine for reliable off-grid sandbox/testing

  String _localClientId = 'NODE-P1';
  String _activeRecipientId = 'NODE-P2';

  List<MessageMail> _conversationMessages = [];
  List<MessageMail> _allMessages = [];
  Map<String, int> _dbStats = {
    'PENDING_LOCAL': 0,
    'IN_TRANSIT': 0,
    'DELIVERED': 0,
    'FAILED': 0,
    'TOTAL': 0,
  };

  bool _isSyncing = false;
  bool _isDisposed = false;
  StreamSubscription? _bridgeStateSub;
  StreamSubscription? _syncSub;

  // Getters
  String get localClientId => _localClientId;
  String get activeRecipientId => _activeRecipientId;
  List<MessageMail> get conversationMessages => _conversationMessages;
  List<MessageMail> get allMessages => _allMessages;
  Map<String, int> get dbStats => _dbStats;
  bool get isSyncing => _isSyncing;
  bool get isUsingMock => _isUsingMock;

  BleHardwareBridge get bridge => _bridge;
  BleConnectionState get bleState => _bridge.state;
  String? get connectedNodeName => _bridge.connectedNodeName;
  int get rssi => _bridge.rssi;
  int get pingLatencyMs => _bridge.pingLatencyMs;
  int get pendingSyncCount => _dbStats['PENDING_LOCAL'] ?? 0;

  bool get isConnected => _bridge.state == BleConnectionState.connected;

  MessageMailProvider({
    required this.db,
    required this.audio,
    BleHardwareBridge? bridge,
    bool startConnected = false,
  }) {
    if (bridge != null) {
      _bridge = bridge;
    } else {
      bool isMobile = false;
      try {
        isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
      } catch (_) {}
      _bridge = isMobile ? FlutterBluePlusBridge() : MockBleNodeEngine();
    }
    _isUsingMock = _bridge is MockBleNodeEngine;
    _initCoordinator();
    _loadData();

    if (startConnected && _bridge is MockBleNodeEngine) {
      _bridge.connectToNode('NODE-P1');
    }
  }

  void _initCoordinator() {
    _coordinator = BleSyncCoordinator(
      bridge: _bridge,
      db: db,
      localNodeId: _localClientId,
      activeRecipientId: _activeRecipientId,
    );

    _bridgeStateSub = _bridge.stateStream.listen((_) {
      notifyListeners();
    });

    _syncSub = _coordinator.onSyncCompleted.listen((_) {
      _loadData();
    });
  }

  Future<void> _loadData() async {
    if (_isDisposed) return;
    final conv = await db.getMessagesForConversation(_activeRecipientId);
    if (_isDisposed) return;
    final all = await db.getAllMessages();
    if (_isDisposed) return;
    final stats = await db.getDatabaseStats();
    if (_isDisposed) return;

    _conversationMessages = conv;
    _allMessages = all;
    _dbStats = stats;
    notifyListeners();
  }

  /// Sets active conversation contact/recipient.
  void setActiveRecipient(String recipientId) {
    _activeRecipientId = recipientId;
    _coordinator.activeRecipientId = recipientId;
    _loadData();
  }

  /// Sets local device client identifier.
  void setLocalClientId(String clientId) {
    _localClientId = clientId;
    _coordinator.localNodeId = clientId;
    if (_activeRecipientId == clientId) {
      _activeRecipientId = clientId == 'NODE-P1' ? 'NODE-P2' : 'NODE-P1';
      _coordinator.activeRecipientId = _activeRecipientId;
    }
    _loadData();
  }

  /// Toggles between Physical BLE Client and Mock BLE Node Engine.
  Future<void> toggleHardwareBridge(bool useMock) async {
    if (_isUsingMock == useMock) return;

    await _bridge.disconnect();
    _bridge.dispose();
    _bridgeStateSub?.cancel();
    _syncSub?.cancel();
    _coordinator.dispose();

    _isUsingMock = useMock;
    _bridge = useMock ? MockBleNodeEngine() : FlutterBluePlusBridge();
    _initCoordinator();
    notifyListeners();
  }

  /// Sends a text message:
  /// Enqueues into SQLite as PENDING_LOCAL.
  /// If connected, auto-flushes to node via coordinator.
  Future<void> sendTextMessage(String text) async {
    if (text.trim().isEmpty) return;

    final message = MessageMail(
      id: _uuid.v4(),
      senderId: _localClientId,
      recipientId: _activeRecipientId,
      payloadType: PayloadType.text,
      textContent: text.trim(),
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.pendingLocal,
    );

    await db.saveOutgoingMessage(message);
    await _loadData();

    if (isConnected) {
      await manualMeshSync();
    }
  }

  /// Sends a compressed voice mail:
  /// Enqueues into SQLite as PENDING_LOCAL.
  /// If connected, auto-flushes to node via coordinator.
  Future<void> sendVoiceMail(Uint8List audioBlob) async {
    final message = MessageMail(
      id: _uuid.v4(),
      senderId: _localClientId,
      recipientId: _activeRecipientId,
      payloadType: PayloadType.voiceMail,
      audioBlob: audioBlob,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.pendingLocal,
    );

    await db.saveOutgoingMessage(message);
    await _loadData();

    if (isConnected) {
      await manualMeshSync();
    }
  }

  /// Scans for physical or mock LoRa nodes.
  Future<void> scanForNode() async {
    await _bridge.startScan();
  }

  /// Manually triggers a sync/flush of all pending outbox records.
  Future<void> manualMeshSync() async {
    if (!isConnected || _isSyncing) return;
    _isSyncing = true;
    notifyListeners();

    try {
      await _coordinator.flushOutbox();
    } finally {
      _isSyncing = false;
      await _loadData();
    }
  }

  /// Connects to a physical or mock Heltec LoRa node.
  Future<bool> connectToNode(String nodeId) async {
    final success = await _bridge.connectToNode(nodeId);
    if (success) {
      await _loadData();
    }
    return success;
  }

  /// Disconnects from the current node.
  Future<void> disconnectFromNode() async {
    await _bridge.disconnect();
    notifyListeners();
  }

  /// Resets stuck IN_TRANSIT or FAILED messages back to PENDING_LOCAL.
  Future<void> resetStuckQueue() async {
    await db.resetStuckQueueToPending();
    await _loadData();
  }

  /// Deletes a specific message.
  Future<void> deleteMessage(String id) async {
    await db.deleteMessage(id);
    await _loadData();
  }

  /// Clears the entire database (diagnostic tool).
  Future<void> clearAllDatabase() async {
    await db.clearAllMessages();
    await _loadData();
  }

  // --- Diagnostic Simulation Helpers ---
  void simulateIncomingMessage({
    required String text,
    String? senderNodeId,
  }) {
    if (_bridge is MockBleNodeEngine) {
      final engine = _bridge as MockBleNodeEngine;
      engine.simulateIncomingText(
        messageId: _uuid.v4(),
        senderNodeId: senderNodeId ?? _activeRecipientId,
        text: text,
      );
    }
  }

  void simulateIncomingVoiceMail({
    String? senderNodeId,
  }) {
    if (_bridge is MockBleNodeEngine) {
      final engine = _bridge as MockBleNodeEngine;
      final voiceBlob = AudioService.generateSyntheticVoiceMail(seconds: 4.0);
      engine.simulateIncomingVoice(
        messageId: _uuid.v4(),
        senderNodeId: senderNodeId ?? _activeRecipientId,
        audioBlob: voiceBlob,
      );
    }
  }

  void simulateLoRaAck(String messageId, {bool isDelivered = true}) {
    if (_bridge is MockBleNodeEngine) {
      final engine = _bridge as MockBleNodeEngine;
      engine.simulateIncomingAck(
        messageId: messageId,
        recipientId: _localClientId,
        isDelivered: isDelivered,
      );
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _bridgeStateSub?.cancel();
    _syncSub?.cancel();
    _coordinator.dispose();
    _bridge.dispose();
    super.dispose();
  }
}

