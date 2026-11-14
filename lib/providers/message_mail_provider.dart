import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../models/message_mail.dart';
import '../protocol/ble_packet_codec.dart';
import '../services/audio_service.dart';
import '../services/ble_service.dart';
import '../services/database_service.dart';
import '../services/mock_ble_node_engine.dart';
import '../services/native_platform_service.dart';

class MessageMailProvider extends ChangeNotifier {
  final DatabaseService db;
  final AudioService audio;
  final NativePlatformService nativePlatform;
  final Uuid _uuid = const Uuid();

  late BleHardwareBridge _bridge;
  late BleSyncCoordinator _coordinator;
  bool _isUsingMock = false;
  bool _isDisposed = false;
  bool _isSyncing = false;
  bool _isInitialized = false;

  LocalProfile? _profile;
  String? _nameConflictMessage;

  List<PeerUser> _peers = [];
  List<ChatGroup> _groups = [];
  List<ChatSummary> _chatSummaries = [];
  List<MessageMail> _activeChatMessages = [];
  List<MessageMail> _allMessages = [];
  String? _activeChatId;

  Map<String, int> _dbStats = {
    'PENDING_LOCAL': 0,
    'IN_TRANSIT': 0,
    'DELIVERED': 0,
    'FAILED': 0,
    'TOTAL': 0,
  };

  // Call State
  CallSessionState _callState = const CallSessionState();
  Timer? _ringTimeoutTimer;
  Timer? _acceptResendTimer;
  bool _isPromotingCall = false;
  int _callAudioSeq = 0;

  StreamSubscription? _bridgeStateSub;
  StreamSubscription? _syncSub;
  StreamSubscription? _conflictSub;
  StreamSubscription? _msgNotifySub;
  StreamSubscription? _callSignalSub;
  StreamSubscription? _callAudioSub;
  StreamSubscription? _nativeEventSub;
  StreamSubscription? _audioPlayerSub;

  final StreamController<({String chatId, bool isGroup})> _openChatNavController =
      StreamController<({String chatId, bool isGroup})>.broadcast();
  Stream<({String chatId, bool isGroup})> get openChatNavigationStream =>
      _openChatNavController.stream;

  // Getters
  bool get isInitialized => _isInitialized;
  bool get isOnboarded => _profile != null && _profile!.username.isNotEmpty;
  LocalProfile? get profile => _profile;
  String get localUsername => _profile?.username ?? '';
  String get localDisplayName => _profile?.displayName ?? '';
  String? get nameConflictMessage => _nameConflictMessage;

  List<PeerUser> get peers => _peers;
  List<ChatGroup> get groups => _groups;
  List<ChatSummary> get chatSummaries => _chatSummaries;
  List<MessageMail> get activeChatMessages => _activeChatMessages;
  List<MessageMail> get allMessages => _allMessages;
  String? get activeChatId => _activeChatId;
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

  CallSessionState get callState => _callState;

  MessageMailProvider({
    required this.db,
    required this.audio,
    NativePlatformService? nativePlatform,
    BleHardwareBridge? bridge,
    bool autoInit = true,
  }) : nativePlatform = nativePlatform ?? NativePlatformService() {
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

    _coordinator = BleSyncCoordinator(
      bridge: _bridge,
      db: db,
      localDeviceUuid: _uuid.v4(),
      localUsername: '',
      localDisplayName: '',
    );
    _attachSubscriptions();

    if (autoInit) {
      initialize();
    }
  }

  Future<void> initialize() async {
    if (_isDisposed) return;
    _profile = await db.getLocalProfile();
    if (_profile != null) {
      _coordinator.localDeviceUuid = _profile!.deviceUuid;
      _coordinator.localUsername = _profile!.username;
      _coordinator.localDisplayName = _profile!.displayName;
      await nativePlatform.startMeshService(
        username: _profile!.username,
        statusText: 'Off-Grid Radar Active (${_profile!.displayName})',
      );
      if (isConnected) {
        await _coordinator.sendPresenceHello();
      }
    }

    await _loadData();
    _isInitialized = true;
    notifyListeners();

    final pendingNav = await nativePlatform.consumePendingEvent();
    if (pendingNav != null) {
      _handleNativeEvent(pendingNav);
    }
  }

  void _attachSubscriptions() {
    _bridgeStateSub = _bridge.stateStream.listen((state) {
      if (_profile != null) {
        final statusText = state == BleConnectionState.connected
            ? 'Connected as ${_profile!.displayName} (${_bridge.rssi} dBm)'
            : state == BleConnectionState.scanning
                ? 'Scanning for Off-Grid Relay...'
                : 'Off-Grid Radar Standby (${_profile!.displayName})';
        nativePlatform.updateServiceStatus(statusText);
      }
      notifyListeners();
    });

    _syncSub = _coordinator.onSyncCompleted.listen((_) {
      _loadData();
    });

    _conflictSub = _coordinator.onNameConflict.listen((takenName) {
      _nameConflictMessage =
          'Name "$takenName" is already used by another phone on this relay. Please choose a unique name.';
      notifyListeners();
    });

    _msgNotifySub = _coordinator.onIncomingMessageNotify.listen((msg) async {
      final senderLabel = resolveDisplayName(msg.senderId);
      String title = senderLabel;
      if (msg.isGroup) {
        final grp = _groups.where((g) => g.groupId == msg.chatId).firstOrNull;
        final grpTitle = grp?.groupName ?? msg.chatId;
        title = '$grpTitle • $senderLabel';
      }
      final body = msg.payloadType == PayloadType.voiceMail
          ? '🎤 Voice message (${_formatDurationMs(msg.durationMs)})'
          : (msg.textContent ?? 'New message');
      await nativePlatform.showMessageNotification(
        chatId: msg.chatId,
        title: title,
        body: body,
        isGroup: msg.isGroup,
      );
    });

    _callSignalSub = _coordinator.onCallSignal.listen(_handleIncomingCallSignal);
    _callAudioSub = _coordinator.onCallAudio.listen(_handleIncomingCallAudio);
    _nativeEventSub = nativePlatform.eventStream.listen(_handleNativeEvent);
    _audioPlayerSub = audio.playerStateStream.listen((_) {
      if (!_isDisposed) notifyListeners();
    });
  }

  void setAppForeground(bool inForeground) {
    _coordinator.isAppInForeground = inForeground;
  }

  Future<void> _loadData() async {
    if (_isDisposed) return;
    final me = _profile?.username ?? '';
    _peers = await db.getPeers(excludeUsername: me.isEmpty ? null : me);
    _groups = await db.getGroups();
    _chatSummaries = me.isEmpty ? [] : await db.getChatSummaries(me);
    _allMessages = await db.getAllMessages();
    _dbStats = await db.getDatabaseStats();

    if (_activeChatId != null) {
      _activeChatMessages = await db.getMessagesForChat(_activeChatId!);
    }
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  /// Registers or updates the user's unique off-grid name.
  Future<bool> registerUsername(String rawDisplayName) async {
    final trimmed = rawDisplayName.trim();
    final handle = BlePacketCodec.normalizeUsername(trimmed);
    if (handle.length < 2) return false;

    final deviceUuid = _profile?.deviceUuid ?? _uuid.v4();
    final newProfile = LocalProfile(
      deviceUuid: deviceUuid,
      username: handle,
      displayName: trimmed,
      isVerifiedOnRelay: false,
    );

    _profile = newProfile;
    _nameConflictMessage = null;
    await db.saveLocalProfile(newProfile);

    _coordinator.localDeviceUuid = deviceUuid;
    _coordinator.localUsername = handle;
    _coordinator.localDisplayName = trimmed;

    await nativePlatform.startMeshService(
      username: handle,
      statusText: 'Off-Grid Radar Active ($trimmed)',
    );

    if (isConnected) {
      await _coordinator.sendPresenceHello();
    }

    await _loadData();
    _isInitialized = true;
    notifyListeners();
    return true;
  }

  void clearNameConflict() {
    _nameConflictMessage = null;
    notifyListeners();
  }

  String resolveDisplayName(String username) {
    if (username == localUsername && localDisplayName.isNotEmpty) {
      return localDisplayName;
    }
    final peer = _peers.where((p) => p.username == username).firstOrNull;
    return peer?.displayName ?? username;
  }

  PeerUser? getPeer(String username) {
    return _peers.where((p) => p.username == username).firstOrNull;
  }

  ChatGroup? getGroup(String groupId) {
    return _groups.where((g) => g.groupId == groupId).firstOrNull;
  }

  Future<void> openChat(String chatId) async {
    _activeChatId = chatId;
    _coordinator.activeOpenChatId = chatId;
    await db.markChatAsRead(chatId);
    _activeChatMessages = await db.getMessagesForChat(chatId);
    await _loadData();
  }

  void closeChat() {
    _activeChatId = null;
    _coordinator.activeOpenChatId = null;
    _activeChatMessages = [];
    notifyListeners();
  }

  /// Creates a new WhatsApp-style group and syncs membership over BLE.
  Future<ChatGroup?> createGroup({
    required String groupName,
    required List<String> memberUsernames,
  }) async {
    if (_profile == null) return null;
    final cleanName = groupName.trim();
    if (cleanName.isEmpty) return null;

    final groupId = 'g_${_uuid.v4().replaceAll('-', '').substring(0, 8)}';
    final members = <String>{
      _profile!.username,
      ...memberUsernames.map((m) => BlePacketCodec.normalizeUsername(m)).where((m) => m.isNotEmpty),
    }.toList();

    final group = ChatGroup(
      groupId: groupId,
      groupName: cleanName,
      createdBy: _profile!.username,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      members: members,
    );

    await db.saveGroup(group);
    if (isConnected) {
      await _coordinator.sendGroupMeta(group);
    }
    await _loadData();
    return group;
  }

  /// Sends a compressed text message to a user or group.
  Future<void> sendTextMessage(
    String chatId,
    String text, {
    bool isGroup = false,
  }) async {
    if (_profile == null || text.trim().isEmpty) return;

    final message = MessageMail(
      id: _uuid.v4(),
      chatId: chatId,
      senderId: _profile!.username,
      recipientId: chatId,
      isGroup: isGroup,
      payloadType: PayloadType.text,
      textContent: text.trim(),
      isRead: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.pendingLocal,
    );

    await db.saveOutgoingMessage(message);
    await _loadData();

    if (isConnected) {
      await manualMeshSync();
    }
  }

  /// Sends a compressed voice note (AMR-NB / AAC-LC) chunked over BLE.
  Future<void> sendVoiceMail(
    String chatId,
    RecordedVoiceNote voice, {
    bool isGroup = false,
  }) async {
    if (_profile == null || voice.bytes.isEmpty) return;

    final message = MessageMail(
      id: _uuid.v4(),
      chatId: chatId,
      senderId: _profile!.username,
      recipientId: chatId,
      isGroup: isGroup,
      payloadType: PayloadType.voiceMail,
      audioBlob: voice.bytes,
      durationMs: voice.durationMs,
      codecType: voice.codecType,
      isRead: true,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.pendingLocal,
    );

    await db.saveOutgoingMessage(message);
    await _loadData();

    if (isConnected) {
      await manualMeshSync();
    }
  }

  // ===========================================================================
  // Live Calling + Unanswered Voicemail Fallback
  // ===========================================================================

  Future<void> startVoiceCall(String targetUsername) async {
    if (_profile == null || _callState.isActive) return;
    final displayName = resolveDisplayName(targetUsername);

    // If relay itself is disconnected, offer voicemail immediately
    if (!isConnected) {
      _callState = CallSessionState(
        callId: _uuid.v4(),
        peerUsername: targetUsername,
        peerDisplayName: displayName,
        phase: CallPhase.unansweredPrompt,
        endReason: '$displayName is currently out of relay range.',
      );
      notifyListeners();
      return;
    }

    final callId = _uuid.v4();
    _callState = CallSessionState(
      callId: callId,
      peerUsername: targetUsername,
      peerDisplayName: displayName,
      phase: CallPhase.calling,
    );
    notifyListeners();

    await nativePlatform.startRingbackTone();
    final frame = BlePacketCodec.encodeCallSignal(
      callId: callId,
      senderId: _profile!.username,
      targetId: targetUsername,
      signalCode: CallSignalCode.invite,
    );
    await _bridge.sendReliablePacket(frame);

    _ringTimeoutTimer?.cancel();
    _ringTimeoutTimer = Timer(const Duration(seconds: 25), () async {
      if (_callState.phase == CallPhase.calling ||
          _callState.phase == CallPhase.ringing) {
        await nativePlatform.stopRingbackTone();
        final cancelFrame = BlePacketCodec.encodeCallSignal(
          callId: callId,
          senderId: _profile!.username,
          targetId: targetUsername,
          signalCode: CallSignalCode.hangup,
        );
        await _bridge.sendReliablePacket(cancelFrame);
        _callState = _callState.copyWith(
          phase: CallPhase.unansweredPrompt,
          endReason: '$displayName did not answer.',
        );
        notifyListeners();
      }
    });
  }

  Future<void> acceptIncomingCall() async {
    if (_profile == null ||
        _callState.phase != CallPhase.incoming ||
        _callState.callId == null ||
        _callState.peerUsername == null) {
      return;
    }

    final activeCallId = _callState.callId!;
    final targetUser = _callState.peerUsername!;
    _callAudioSeq = 0;
    _callState = _callState.copyWith(
      phase: CallPhase.connected,
      connectedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();

    await nativePlatform.stopIncomingCallAlert();

    final acceptFrame = BlePacketCodec.encodeCallSignal(
      callId: activeCallId,
      senderId: _profile!.username,
      targetId: targetUser,
      signalCode: CallSignalCode.accept,
    );
    await _bridge.sendReliablePacket(acceptFrame);
    await _bridge.setHighPriorityConnection(true);

    // Resend ACCEPT once after priority negotiation stabilizes to prevent missed caller transition
    _acceptResendTimer?.cancel();
    _acceptResendTimer = Timer(const Duration(milliseconds: 320), () {
      if (_callState.phase == CallPhase.connected &&
          _callState.callId == activeCallId) {
        _bridge.sendReliablePacket(acceptFrame);
      }
    });

    await _startLiveCallStreaming();
  }

  Future<void> declineIncomingCall() async {
    if (_profile == null || _callState.callId == null || _callState.peerUsername == null) {
      await nativePlatform.stopIncomingCallAlert();
      _callState = const CallSessionState();
      notifyListeners();
      return;
    }

    await nativePlatform.stopIncomingCallAlert();
    final rejectFrame = BlePacketCodec.encodeCallSignal(
      callId: _callState.callId!,
      senderId: _profile!.username,
      targetId: _callState.peerUsername!,
      signalCode: CallSignalCode.reject,
    );
    await _bridge.sendReliablePacket(rejectFrame);

    await _logCallInChat(
      peerUsername: _callState.peerUsername!,
      label: 'Declined incoming call',
      durationMs: 0,
    );
    _callState = const CallSessionState();
    notifyListeners();
  }

  Future<void> endActiveCall() async {
    _ringTimeoutTimer?.cancel();
    _acceptResendTimer?.cancel();
    _isPromotingCall = false;
    await nativePlatform.stopRingbackTone();
    await nativePlatform.stopIncomingCallAlert();
    await audio.stopLiveCallAudio();
    await _bridge.setHighPriorityConnection(false);

    if (_profile != null &&
        _callState.callId != null &&
        _callState.peerUsername != null) {
      final hangupFrame = BlePacketCodec.encodeCallSignal(
        callId: _callState.callId!,
        senderId: _profile!.username,
        targetId: _callState.peerUsername!,
        signalCode: CallSignalCode.hangup,
      );
      await _bridge.sendReliablePacket(hangupFrame);

      final durationMs = _callState.connectedAtMs != null
          ? DateTime.now().millisecondsSinceEpoch - _callState.connectedAtMs!
          : 0;
      await _logCallInChat(
        peerUsername: _callState.peerUsername!,
        label: durationMs > 0
            ? 'Voice call (${_formatDurationMs(durationMs)})'
            : 'Cancelled call',
        durationMs: durationMs,
      );
    }

    _callState = const CallSessionState();
    notifyListeners();
  }

  void openVoicemailRecorderAfterMissedCall() {
    if (_callState.phase != CallPhase.unansweredPrompt) return;
    _callState = _callState.copyWith(phase: CallPhase.recordingVoicemail);
    notifyListeners();
  }

  Future<void> sendVoicemailFromMissedCall(RecordedVoiceNote voice) async {
    final target = _callState.peerUsername;
    if (target != null) {
      await _logCallInChat(
        peerUsername: target,
        label: 'Unanswered call • Left voicemail',
        durationMs: 0,
      );
      await sendVoiceMail(target, voice, isGroup: false);
    }
    _callState = const CallSessionState();
    notifyListeners();
  }

  Future<void> cutUnansweredCall() async {
    if (_callState.peerUsername != null) {
      await _logCallInChat(
        peerUsername: _callState.peerUsername!,
        label: 'Unanswered call',
        durationMs: 0,
      );
    }
    _callState = const CallSessionState();
    notifyListeners();
  }

  void toggleCallMute() {
    final next = !_callState.isMuted;
    audio.setMicMuted(next);
    _callState = _callState.copyWith(isMuted: next);
    notifyListeners();
  }

  Future<void> toggleCallSpeaker() async {
    final next = !_callState.isSpeakerOn;
    await audio.setSpeakerphone(next);
    _callState = _callState.copyWith(isSpeakerOn: next);
    notifyListeners();
  }

  Future<void> _startLiveCallStreaming() async {
    final target = _callState.peerUsername;
    final callId = _callState.callId;
    if (_profile == null || target == null || callId == null) return;

    await audio.startLiveCallAudio(
      speakerOn: _callState.isSpeakerOn,
      initialMuted: _callState.isMuted,
      onEncodedFrame: (frame) {
        if (_callState.phase != CallPhase.connected) return;
        final packetBytes = BlePacketCodec.encodeCallAudio(
          callId: callId,
          senderId: _profile!.username,
          targetId: target,
          seqNum: _callAudioSeq++,
          predictor: frame.initialPredictor,
          stepIndex: frame.initialStepIndex,
          frameMs: 40,
          adpcmBytes: frame.nibbles,
        );
        _bridge.sendUrgentPacket(packetBytes);
      },
    );
  }

  Future<void> _handleIncomingCallSignal(BlePacket packet) async {
    if (_profile == null || packet.payload.isEmpty) return;
    final sigCode = packet.payload[0];
    final peerUser = packet.senderId;
    final peerDisplay = resolveDisplayName(peerUser);

    switch (sigCode) {
      case CallSignalCode.invite:
        if (_callState.isActive) {
          final busyFrame = BlePacketCodec.encodeCallSignal(
            callId: packet.messageId,
            senderId: _profile!.username,
            targetId: peerUser,
            signalCode: CallSignalCode.busy,
          );
          await _bridge.sendReliablePacket(busyFrame);
          return;
        }
        _callState = CallSessionState(
          callId: packet.messageId,
          peerUsername: peerUser,
          peerDisplayName: peerDisplay,
          phase: CallPhase.incoming,
        );
        notifyListeners();

        // Confirm ringing back to caller & trigger native full-screen ringtone alert
        final ringFrame = BlePacketCodec.encodeCallSignal(
          callId: packet.messageId,
          senderId: _profile!.username,
          targetId: peerUser,
          signalCode: CallSignalCode.ringing,
        );
        await _bridge.sendReliablePacket(ringFrame);
        await nativePlatform.showIncomingCall(
          callId: packet.messageId,
          callerId: peerUser,
          callerName: peerDisplay,
        );
        break;

      case CallSignalCode.ringing:
        if (_callState.callId == packet.messageId &&
            _callState.phase == CallPhase.calling) {
          _callState = _callState.copyWith(phase: CallPhase.ringing);
          notifyListeners();
        }
        break;

      case CallSignalCode.accept:
        if (_callState.callId == packet.messageId &&
            _callState.phase != CallPhase.connected) {
          await _promoteOutgoingCallToConnected();
        }
        break;

      case CallSignalCode.reject:
      case CallSignalCode.busy:
      case CallSignalCode.unavailable:
        if (_callState.callId == packet.messageId) {
          _ringTimeoutTimer?.cancel();
          _acceptResendTimer?.cancel();
          _isPromotingCall = false;
          await nativePlatform.stopRingbackTone();
          final reason = sigCode == CallSignalCode.busy
              ? '$peerDisplay is on another call.'
              : sigCode == CallSignalCode.unavailable
                  ? '$peerDisplay is not connected to the relay right now.'
                  : '$peerDisplay declined the call.';
          _callState = _callState.copyWith(
            phase: CallPhase.unansweredPrompt,
            endReason: reason,
          );
          notifyListeners();
        }
        break;

      case CallSignalCode.hangup:
        if (_callState.callId == packet.messageId) {
          _ringTimeoutTimer?.cancel();
          _acceptResendTimer?.cancel();
          _isPromotingCall = false;
          await nativePlatform.stopRingbackTone();
          await nativePlatform.stopIncomingCallAlert();
          await audio.stopLiveCallAudio();
          await _bridge.setHighPriorityConnection(false);

          final dur = _callState.connectedAtMs != null
              ? DateTime.now().millisecondsSinceEpoch - _callState.connectedAtMs!
              : 0;
          final label = _callState.phase == CallPhase.incoming
              ? 'Missed call from $peerDisplay'
              : dur > 0
                  ? 'Voice call (${_formatDurationMs(dur)})'
                  : 'Call ended';
          await _logCallInChat(
            peerUsername: peerUser,
            label: label,
            durationMs: dur,
          );
          _callState = const CallSessionState();
          notifyListeners();
        }
        break;
    }
  }

  /// Transitions the caller immediately to live connected audio + controls
  /// (invoked either by CallSignalCode.accept OR as fallback when live call audio arrives).
  Future<void> _promoteOutgoingCallToConnected() async {
    if (_isPromotingCall || _callState.phase == CallPhase.connected) return;
    _isPromotingCall = true;
    _ringTimeoutTimer?.cancel();
    _callAudioSeq = 0;

    // Synchronously update phase so Mute/Speaker/End Call and audio RX work right away
    _callState = _callState.copyWith(
      phase: CallPhase.connected,
      connectedAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();

    try {
      await nativePlatform.stopRingbackTone();
      await _bridge.setHighPriorityConnection(true);
      await _startLiveCallStreaming();
    } finally {
      _isPromotingCall = false;
    }
  }

  void _handleIncomingCallAudio(BlePacket packet) {
    if (_callState.callId != packet.messageId) return;

    // Fallback: if ACCEPT signaling packet dropped over BLE, live audio proves callee answered!
    if (_callState.phase == CallPhase.calling ||
        _callState.phase == CallPhase.ringing) {
      unawaited(_promoteOutgoingCallToConnected());
    } else if (_callState.phase != CallPhase.connected) {
      return;
    }

    try {
      final audioFrame = BlePacketCodec.decodeCallAudio(packet.payload);
      audio.feedIncomingCallAudio(audioFrame);
    } catch (_) {}
  }

  Future<void> _logCallInChat({
    required String peerUsername,
    required String label,
    required int durationMs,
  }) async {
    if (_profile == null) return;
    final msg = MessageMail(
      id: _uuid.v4(),
      chatId: peerUsername,
      senderId: _profile!.username,
      recipientId: peerUsername,
      isGroup: false,
      payloadType: PayloadType.callLog,
      textContent: label,
      durationMs: durationMs,
      isRead: _activeChatId == peerUsername,
      timestamp: DateTime.now().millisecondsSinceEpoch,
      status: MessageStatus.delivered,
    );
    await db.saveOutgoingMessage(msg);
    await _loadData();
  }

  void _handleNativeEvent(Map<String, dynamic> event) {
    final type = event['type'] as String?;
    switch (type) {
      case 'open_chat':
        final chatId = event['chatId'] as String?;
        final isGroup = (event['isGroup'] as bool?) ?? false;
        if (chatId != null && chatId.isNotEmpty) {
          _openChatNavController.add((chatId: chatId, isGroup: isGroup));
        }
        break;
      case 'accept_call':
        if (_callState.phase == CallPhase.incoming) {
          acceptIncomingCall();
        }
        break;
      case 'decline_call':
        if (_callState.phase == CallPhase.incoming) {
          declineIncomingCall();
        }
        break;
    }
  }

  // ===========================================================================
  // Sync & Hardware Diagnostics Controls
  // ===========================================================================

  Future<void> toggleHardwareBridge(bool useMock) async {
    if (_isUsingMock == useMock) return;
    await _bridge.disconnect();
    _bridge.dispose();
    _bridgeStateSub?.cancel();
    _syncSub?.cancel();
    _conflictSub?.cancel();
    _msgNotifySub?.cancel();
    _callSignalSub?.cancel();
    _callAudioSub?.cancel();
    _coordinator.dispose();

    _isUsingMock = useMock;
    _bridge = useMock ? MockBleNodeEngine() : FlutterBluePlusBridge();
    _coordinator = BleSyncCoordinator(
      bridge: _bridge,
      db: db,
      localDeviceUuid: _profile?.deviceUuid ?? _uuid.v4(),
      localUsername: _profile?.username ?? '',
      localDisplayName: _profile?.displayName ?? '',
    );
    _attachSubscriptions();
    notifyListeners();
  }

  Future<void> scanForNode() async => _bridge.startScan();

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

  Future<bool> connectToNode(String nodeId) async {
    final ok = await _bridge.connectToNode(nodeId);
    if (ok) await _loadData();
    return ok;
  }

  Future<void> disconnectFromNode() async {
    await _bridge.disconnect();
    notifyListeners();
  }

  Future<void> resetStuckQueue() async {
    await db.resetStuckQueueToPending();
    await _loadData();
  }

  Future<void> deleteMessage(String id) async {
    await db.deleteMessage(id);
    await _loadData();
  }

  Future<void> clearAllDatabase() async {
    await db.clearAllMessages();
    await _loadData();
  }

  static String _formatDurationMs(int ms) {
    final totalSec = (ms / 1000).round();
    final mins = totalSec ~/ 60;
    final secs = totalSec % 60;
    return '$mins:${secs.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _isDisposed = true;
    _ringTimeoutTimer?.cancel();
    _acceptResendTimer?.cancel();
    _bridgeStateSub?.cancel();
    _syncSub?.cancel();
    _conflictSub?.cancel();
    _msgNotifySub?.cancel();
    _callSignalSub?.cancel();
    _callAudioSub?.cancel();
    _nativeEventSub?.cancel();
    _audioPlayerSub?.cancel();
    _openChatNavController.close();
    _coordinator.dispose();
    _bridge.dispose();
    nativePlatform.dispose();
    super.dispose();
  }
}
