import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/message_mail.dart';
import '../protocol/ble_packet_codec.dart';
import 'database_service.dart';

/// GATT Constants matching ESP32 Firmware (`esp32_devkit_v1_relay.ino`).
class BleGattConstants {
  static final Guid serviceUuid =
      Guid('0000A101-0000-1000-8000-00805F9B34FB');
  static final Guid charDataTx =
      Guid('0000A102-0000-1000-8000-00805F9B34FB');
  static final Guid charDataRx =
      Guid('0000A103-0000-1000-8000-00805F9B34FB');
}

enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
}

abstract class BleHardwareBridge {
  BleConnectionState get state;
  String? get connectedNodeName;
  int get rssi;
  int get pingLatencyMs;
  Stream<BleConnectionState> get stateStream;
  Stream<BlePacket> get packetRxStream;

  Future<void> startScan();
  Future<void> stopScan();
  Future<bool> connectToNode(String nodeIdOrAddress);
  Future<void> disconnect();
  Future<bool> sendPacket(Uint8List frameBytes);
  Future<bool> sendUrgentPacket(Uint8List frameBytes);
  Future<bool> sendReliablePacket(Uint8List frameBytes);
  Future<void> setHighPriorityConnection(bool high);
  void dispose();
}

/// Real BLE GATT client with autonomous background radar, MTU 512 negotiation,
/// paced chunk writes, and drop-stale urgent lane for live calling.
class FlutterBluePlusBridge implements BleHardwareBridge {
  BleConnectionState _state = BleConnectionState.disconnected;
  String? _connectedNodeName;
  int _rssi = -85;
  final int _pingLatencyMs = 20;

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription<List<int>>? _rxSubscription;
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothConnectionState>? _deviceConnSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  Timer? _radarTimer;
  Timer? _rssiPollTimer;
  bool _isAutoRadarActive = true;
  bool _isConnecting = false;

  // Serializes BLE writes cleanly while allowing stale-frame drop for live call audio
  Future<void> _writeTail = Future<void>.value();
  int _pendingUrgentWrites = 0;

  final StreamController<BleConnectionState> _stateController =
      StreamController<BleConnectionState>.broadcast();
  final StreamController<BlePacket> _packetRxController =
      StreamController<BlePacket>.broadcast();

  FlutterBluePlusBridge() {
    _initAutoRadar();
  }

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

  void _setState(BleConnectionState newState) {
    if (_state != newState) {
      _state = newState;
      if (!_stateController.isClosed) {
        _stateController.add(newState);
      }
    }
  }

  void _initAutoRadar() {
    _adapterSub = FlutterBluePlus.adapterState.listen((adapterState) {
      if (adapterState == BluetoothAdapterState.on) {
        if (_state == BleConnectionState.disconnected && !_isConnecting) {
          _triggerRadarSweep();
        }
      } else {
        _setState(BleConnectionState.disconnected);
      }
    });

    _radarTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_isAutoRadarActive &&
          _state == BleConnectionState.disconnected &&
          !_isConnecting &&
          !FlutterBluePlus.isScanningNow) {
        _triggerRadarSweep();
      }
    });
  }

  Future<bool> _hasScanPermissions() async {
    try {
      if (!kIsWeb && Platform.isAndroid) {
        final scanGranted = await Permission.bluetoothScan.isGranted;
        final connGranted = await Permission.bluetoothConnect.isGranted;
        if (scanGranted && connGranted) return true;
        // Fallback check for older Android (<12) using location permission
        final locGranted = await Permission.location.isGranted;
        return locGranted;
      }
    } catch (_) {}
    return true;
  }

  Future<void> _triggerRadarSweep() async {
    if (_state == BleConnectionState.connected || _isConnecting) return;
    if (!await _hasScanPermissions()) return;
    try {
      final isSupported = await FlutterBluePlus.isSupported;
      if (!isSupported) return;
      final adapterState = await FlutterBluePlus.adapterState.first;
      if (adapterState != BluetoothAdapterState.on) return;

      await startScan();
    } catch (_) {}
  }

  @override
  Future<void> startScan() async {
    if (_state == BleConnectionState.connected || _isConnecting) return;
    if (!await _hasScanPermissions()) return;
    try {
      _setState(BleConnectionState.scanning);

      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        for (final r in results) {
          final advName = r.advertisementData.advName.toUpperCase();
          final devName = r.device.platformName.toUpperCase();
          final hasService =
              r.advertisementData.serviceUuids.contains(BleGattConstants.serviceUuid);
          final isMatching = hasService ||
              advName.contains('OFFGRID') ||
              advName.contains('ESP32') ||
              advName.contains('DEVKIT') ||
              advName.contains('RELAY') ||
              advName.contains('HELTEC') ||
              advName.contains('NODE') ||
              devName.contains('OFFGRID') ||
              devName.contains('ESP32') ||
              devName.contains('DEVKIT') ||
              devName.contains('RELAY');

          if (isMatching && !_isConnecting && _state != BleConnectionState.connected) {
            _scanSub?.cancel();
            _scanSub = null;
            await FlutterBluePlus.stopScan();
            await connectToNode(r.device.remoteId.str);
            break;
          }
        }
      });

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 7),
        androidUsesFineLocation: false,
      );
    } catch (_) {
      if (_state == BleConnectionState.scanning) {
        _setState(BleConnectionState.disconnected);
      }
    }
  }

  @override
  Future<void> stopScan() async {
    try {
      _scanSub?.cancel();
      _scanSub = null;
      await FlutterBluePlus.stopScan();
    } catch (_) {}
    if (_state == BleConnectionState.scanning) {
      _setState(BleConnectionState.disconnected);
    }
  }

  @override
  Future<bool> connectToNode(String nodeIdOrAddress) async {
    if (_isConnecting) return false;
    _isConnecting = true;
    _setState(BleConnectionState.connecting);

    try {
      await stopScan();
      final device = BluetoothDevice.fromId(nodeIdOrAddress);

      _deviceConnSub?.cancel();
      _deviceConnSub = device.connectionState.listen((connState) {
        if (connState == BluetoothConnectionState.disconnected) {
          _handleDisconnection();
        }
      });

      await device.connect(timeout: const Duration(seconds: 12), autoConnect: false);
      _connectedDevice = device;
      _connectedNodeName = device.platformName.isNotEmpty
          ? device.platformName
          : 'OFFGRID-RELAY';

      try {
        await device.requestMtu(512);
      } catch (_) {}

      final services = await device.discoverServices();
      for (final service in services) {
        if (service.uuid == BleGattConstants.serviceUuid) {
          for (final char in service.characteristics) {
            if (char.uuid == BleGattConstants.charDataTx) {
              _txCharacteristic = char;
            } else if (char.uuid == BleGattConstants.charDataRx) {
              await char.setNotifyValue(true);
              _rxSubscription?.cancel();
              _rxSubscription = char.onValueReceived.listen((data) {
                if (data.isNotEmpty) {
                  try {
                    final packet = BlePacketCodec.decode(Uint8List.fromList(data));
                    if (!_packetRxController.isClosed) {
                      _packetRxController.add(packet);
                    }
                  } catch (_) {}
                }
              });
            }
          }
        }
      }

      try {
        _rssi = await device.readRssi();
      } catch (_) {
        _rssi = -62;
      }

      _rssiPollTimer?.cancel();
      _rssiPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (_connectedDevice != null && _state == BleConnectionState.connected) {
          try {
            _rssi = await _connectedDevice!.readRssi();
            if (!_stateController.isClosed) {
              _stateController.add(_state);
            }
          } catch (_) {}
        }
      });

      _isConnecting = false;
      _setState(BleConnectionState.connected);
      return true;
    } catch (_) {
      _isConnecting = false;
      _handleDisconnection();
      return false;
    }
  }

  @override
  Future<void> setHighPriorityConnection(bool high) async {
    if (_connectedDevice == null || _state != BleConnectionState.connected) return;
    try {
      if (!kIsWeb && Platform.isAndroid) {
        await _connectedDevice!.requestConnectionPriority(
          connectionPriorityRequest:
              high ? ConnectionPriority.high : ConnectionPriority.balanced,
        );
      }
    } catch (_) {}
  }

  void _handleDisconnection() {
    _rssiPollTimer?.cancel();
    _deviceConnSub?.cancel();
    _rxSubscription?.cancel();
    _connectedDevice = null;
    _txCharacteristic = null;
    _connectedNodeName = null;
    _isConnecting = false;
    _setState(BleConnectionState.disconnected);
  }

  @override
  Future<void> disconnect() async {
    _isAutoRadarActive = false;
    await stopScan();
    try {
      await _connectedDevice?.disconnect();
    } catch (_) {}
    _handleDisconnection();
    Future.delayed(const Duration(seconds: 6), () {
      _isAutoRadarActive = true;
    });
  }

  @override
  Future<bool> sendPacket(Uint8List frameBytes) async {
    if (_state != BleConnectionState.connected || _txCharacteristic == null) {
      return false;
    }
    bool ok = false;
    final completer = Completer<bool>();
    _writeTail = _writeTail.then((_) async {
      try {
        if (_state == BleConnectionState.connected && _txCharacteristic != null) {
          await _txCharacteristic!.write(frameBytes, withoutResponse: true);
          ok = true;
          // Gentle pacing for smooth ESP32 Bluedroid RX absorption
          await Future.delayed(const Duration(milliseconds: 12));
        }
      } catch (_) {
        ok = false;
      } finally {
        if (!completer.isCompleted) completer.complete(ok);
      }
    });
    return completer.future;
  }

  @override
  Future<bool> sendUrgentPacket(Uint8List frameBytes) async {
    if (_state != BleConnectionState.connected || _txCharacteristic == null) {
      return false;
    }
    // Drop stale audio frames if BLE queue backs up (> 6 frames = ~240ms)
    if (_pendingUrgentWrites >= 6) {
      return false;
    }
    _pendingUrgentWrites++;
    bool ok = false;
    final completer = Completer<bool>();
    _writeTail = _writeTail.then((_) async {
      try {
        if (_state == BleConnectionState.connected && _txCharacteristic != null) {
          await _txCharacteristic!.write(frameBytes, withoutResponse: true);
          ok = true;
        }
      } catch (_) {
        ok = false;
      } finally {
        _pendingUrgentWrites = max(0, _pendingUrgentWrites - 1);
        if (!completer.isCompleted) completer.complete(ok);
      }
    });
    return completer.future;
  }

  @override
  Future<bool> sendReliablePacket(Uint8List frameBytes) async {
    if (_state != BleConnectionState.connected || _txCharacteristic == null) {
      return false;
    }
    bool ok = false;
    final completer = Completer<bool>();
    _writeTail = _writeTail.then((_) async {
      for (int attempt = 0; attempt < 2; attempt++) {
        try {
          if (_state == BleConnectionState.connected && _txCharacteristic != null) {
            final useWriteWithResponse = _txCharacteristic!.properties.write;
            await _txCharacteristic!.write(
              frameBytes,
              withoutResponse: !useWriteWithResponse,
            );
            ok = true;
            await Future.delayed(const Duration(milliseconds: 8));
            break;
          }
        } catch (_) {
          ok = false;
          await Future.delayed(const Duration(milliseconds: 35));
        }
      }
      if (!completer.isCompleted) completer.complete(ok);
    });
    return completer.future;
  }

  @override
  void dispose() {
    _isAutoRadarActive = false;
    _radarTimer?.cancel();
    _rssiPollTimer?.cancel();
    _adapterSub?.cancel();
    _deviceConnSub?.cancel();
    _scanSub?.cancel();
    _rxSubscription?.cancel();
    try {
      _connectedDevice?.disconnect();
    } catch (_) {}
    _stateController.close();
    _packetRxController.close();
  }
}

class _VoiceAssemblyBuffer {
  final int totalChunks;
  final int durationMs;
  final int codecType;
  final Map<int, Uint8List> chunks = {};

  _VoiceAssemblyBuffer({
    required this.totalChunks,
    required this.durationMs,
    required this.codecType,
  });

  bool get isComplete => chunks.length >= totalChunks;

  Uint8List assemble() {
    final builder = BytesBuilder(copy: false);
    for (int i = 0; i < totalChunks; i++) {
      final part = chunks[i];
      if (part != null) builder.add(part);
    }
    return builder.toBytes();
  }
}

/// Coordinates Protocol v2 Presence, Peer Directory, Group Sync, Voice Chunking,
/// Store-and-Forward Outbox, and Live Call Signal/Audio Routing.
class BleSyncCoordinator {
  final BleHardwareBridge bridge;
  final DatabaseService db;

  String localDeviceUuid;
  String localUsername;
  String localDisplayName;
  String? activeOpenChatId;
  bool isAppInForeground = true;

  StreamSubscription? _stateSub;
  StreamSubscription? _packetSub;
  bool _isFlushing = false;
  bool _isRegisteredOnRelay = false;

  final Map<String, _VoiceAssemblyBuffer> _voiceAssemblers = {};
  final List<DirectoryPeerEntry> _directoryPageAcc = [];

  final StreamController<void> _onSyncCompletedController =
      StreamController<void>.broadcast();
  final StreamController<String> _onNameConflictController =
      StreamController<String>.broadcast();
  final StreamController<MessageMail> _onIncomingMessageNotifyController =
      StreamController<MessageMail>.broadcast();
  final StreamController<BlePacket> _onCallSignalController =
      StreamController<BlePacket>.broadcast();
  final StreamController<BlePacket> _onCallAudioController =
      StreamController<BlePacket>.broadcast();

  Stream<void> get onSyncCompleted => _onSyncCompletedController.stream;
  Stream<String> get onNameConflict => _onNameConflictController.stream;
  Stream<MessageMail> get onIncomingMessageNotify =>
      _onIncomingMessageNotifyController.stream;
  Stream<BlePacket> get onCallSignal => _onCallSignalController.stream;
  Stream<BlePacket> get onCallAudio => _onCallAudioController.stream;

  bool get isRegisteredOnRelay => _isRegisteredOnRelay;

  BleSyncCoordinator({
    required this.bridge,
    required this.db,
    required this.localDeviceUuid,
    required this.localUsername,
    required this.localDisplayName,
  }) {
    _stateSub = bridge.stateStream.listen((state) async {
      if (state == BleConnectionState.connected) {
        _isRegisteredOnRelay = false;
        Future.delayed(const Duration(milliseconds: 350), () async {
          await sendPresenceHello();
        });
      } else if (state == BleConnectionState.disconnected) {
        _isRegisteredOnRelay = false;
        await db.setAllPeersOffline();
        if (!_onSyncCompletedController.isClosed) {
          _onSyncCompletedController.add(null);
        }
      }
    });

    _packetSub = bridge.packetRxStream.listen((packet) {
      _handleIncomingPacket(packet);
    });
  }

  Future<void> sendPresenceHello() async {
    if (bridge.state != BleConnectionState.connected || localUsername.isEmpty) return;
    final frame = BlePacketCodec.encodePresenceHello(
      deviceUuid: localDeviceUuid,
      username: localUsername,
      displayName: localDisplayName,
    );
    await bridge.sendPacket(frame);
  }

  Future<void> requestMailboxSync() async {
    if (bridge.state != BleConnectionState.connected || localUsername.isEmpty) return;
    try {
      final pollFrame = BlePacketCodec.encodePoll(senderId: localUsername);
      await bridge.sendPacket(pollFrame);
    } catch (_) {}
  }

  Future<void> sendGroupMeta(ChatGroup group) async {
    if (bridge.state != BleConnectionState.connected) return;
    final frame = BlePacketCodec.encodeGroupMeta(
      messageId: group.groupId,
      senderId: localUsername,
      groupId: group.groupId,
      groupName: group.groupName,
      members: group.members,
    );
    await bridge.sendPacket(frame);
  }

  /// Flushes all `PENDING_LOCAL` messages (including chunked voice notes).
  Future<int> flushOutbox() async {
    if (bridge.state != BleConnectionState.connected ||
        _isFlushing ||
        localUsername.isEmpty) {
      return 0;
    }
    _isFlushing = true;
    int flushedCount = 0;

    try {
      // Ensure ESP32 knows our groups before sending group messages
      final groups = await db.getGroups();
      for (final g in groups) {
        await sendGroupMeta(g);
      }

      final pending = await db.getPendingOutbox();
      for (final msg in pending) {
        bool allSent = true;
        if (msg.payloadType == PayloadType.text) {
          final frameBytes = BlePacketCodec.encodeText(
            messageId: msg.id,
            senderId: msg.senderId,
            targetId: msg.recipientId,
            text: msg.textContent ?? '',
            isGroup: msg.isGroup,
          );
          allSent = await bridge.sendPacket(frameBytes);
        } else if (msg.payloadType == PayloadType.voiceMail) {
          final chunks = BlePacketCodec.encodeVoiceChunks(
            messageId: msg.id,
            senderId: msg.senderId,
            targetId: msg.recipientId,
            audioBlob: msg.audioBlob ?? Uint8List(0),
            durationMs: msg.durationMs,
            codecType: msg.codecType,
            isGroup: msg.isGroup,
          );
          for (final chunkFrame in chunks) {
            final ok = await bridge.sendPacket(chunkFrame);
            if (!ok) {
              allSent = false;
              break;
            }
          }
        }

        if (allSent) {
          await db.markAsInTransit(msg.id);
          flushedCount++;
        } else {
          await db.incrementRetryCount(msg.id);
        }
      }
    } finally {
      _isFlushing = false;
      if (!_onSyncCompletedController.isClosed) {
        _onSyncCompletedController.add(null);
      }
    }

    return flushedCount;
  }

  Future<void> _handleIncomingPacket(BlePacket packet) async {
    // Fast path: Live Call Audio Frame
    if (packet.isCallAudio) {
      if (!_onCallAudioController.isClosed) {
        _onCallAudioController.add(packet);
      }
      return;
    }

    // Fast path: Call Signaling
    if (packet.isCallSignal) {
      if (!_onCallSignalController.isClosed) {
        _onCallSignalController.add(packet);
      }
      return;
    }

    // Presence Registration Response
    if (packet.isPresence) {
      final status = packet.payload.isNotEmpty ? packet.payload[0] : 0x01;
      if (status == 0x02) {
        _isRegisteredOnRelay = false;
        if (!_onNameConflictController.isClosed) {
          _onNameConflictController.add(localUsername);
        }
      } else {
        _isRegisteredOnRelay = true;
        final prof = await db.getLocalProfile();
        if (prof != null && !prof.isVerifiedOnRelay) {
          await db.saveLocalProfile(prof.copyWith(isVerifiedOnRelay: true));
        }
        await requestMailboxSync();
        await flushOutbox();
      }
      if (!_onSyncCompletedController.isClosed) {
        _onSyncCompletedController.add(null);
      }
      return;
    }

    // Peer Directory Update
    if (packet.isDirectory) {
      final dir = BlePacketCodec.decodePeerDirectory(packet.payload);
      if (dir.page == 0) {
        _directoryPageAcc.clear();
      }
      _directoryPageAcc.addAll(dir.peers);
      if (dir.page >= dir.totalPages - 1) {
        await db.upsertPeers(
          List<DirectoryPeerEntry>.from(_directoryPageAcc),
          markOthersOffline: true,
        );
        _directoryPageAcc.clear();
        if (!_onSyncCompletedController.isClosed) {
          _onSyncCompletedController.add(null);
        }
      }
      return;
    }

    // Group Meta Invitation / Sync
    if (packet.isGroupMeta) {
      try {
        final gm = BlePacketCodec.decodeGroupMeta(packet.targetId, packet.payload);
        final group = ChatGroup(
          groupId: gm.groupId,
          groupName: gm.groupName,
          createdBy: packet.senderId,
          createdAt: DateTime.now().millisecondsSinceEpoch,
          members: gm.members,
        );
        await db.saveGroup(group);
        if (!_onSyncCompletedController.isClosed) {
          _onSyncCompletedController.add(null);
        }
      } catch (_) {}
      return;
    }

    // Delivery ACK
    if (packet.isAck) {
      final statusCode = packet.payload.isNotEmpty ? packet.payload[0] : 0x01;
      final newStatus = statusCode == 0x01 ? 'DELIVERED' : 'FAILED';
      await db.updateStatusByAck(packet.messageId, newStatus);
      if (!_onSyncCompletedController.isClosed) {
        _onSyncCompletedController.add(null);
      }
      return;
    }

    if (packet.isPoll) return;

    // Incoming Text or Chunked Voice Mail
    if (packet.senderId == localUsername) return; // Ignore self echo
    final existing = await db.getMessageById(packet.messageId);
    if (existing != null) {
      // Already received; resend ACK just in case sender missed it
      await _sendDeliveryAck(packet.messageId, packet.senderId);
      return;
    }

    final resolvedChatId = packet.isGroup ? packet.targetId : packet.senderId;
    final isCurrentlyViewingChat =
        isAppInForeground && activeOpenChatId == resolvedChatId;

    if (packet.isText) {
      final msg = MessageMail(
        id: packet.messageId,
        chatId: resolvedChatId,
        senderId: packet.senderId,
        recipientId: packet.targetId,
        isGroup: packet.isGroup,
        payloadType: PayloadType.text,
        textContent: packet.textContent,
        isRead: isCurrentlyViewingChat,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.delivered,
      );
      await db.saveIncomingMessage(msg);
      await _sendDeliveryAck(packet.messageId, packet.senderId);

      if (!isCurrentlyViewingChat && !_onIncomingMessageNotifyController.isClosed) {
        _onIncomingMessageNotifyController.add(msg);
      }
      if (!_onSyncCompletedController.isClosed) {
        _onSyncCompletedController.add(null);
      }
    } else if (packet.isVoice) {
      try {
        final chunk = BlePacketCodec.decodeVoiceChunk(packet.payload);
        final buf = _voiceAssemblers.putIfAbsent(
          packet.messageId,
          () => _VoiceAssemblyBuffer(
            totalChunks: chunk.totalChunks,
            durationMs: chunk.durationMs,
            codecType: chunk.codecType,
          ),
        );
        buf.chunks[chunk.chunkIndex] = chunk.chunkBytes;

        if (buf.isComplete) {
          _voiceAssemblers.remove(packet.messageId);
          final fullAudio = buf.assemble();
          final msg = MessageMail(
            id: packet.messageId,
            chatId: resolvedChatId,
            senderId: packet.senderId,
            recipientId: packet.targetId,
            isGroup: packet.isGroup,
            payloadType: PayloadType.voiceMail,
            audioBlob: fullAudio,
            durationMs: buf.durationMs,
            codecType: buf.codecType,
            isRead: isCurrentlyViewingChat,
            timestamp: DateTime.now().millisecondsSinceEpoch,
            status: MessageStatus.delivered,
          );
          await db.saveIncomingMessage(msg);
          await _sendDeliveryAck(packet.messageId, packet.senderId);

          if (!isCurrentlyViewingChat && !_onIncomingMessageNotifyController.isClosed) {
            _onIncomingMessageNotifyController.add(msg);
          }
          if (!_onSyncCompletedController.isClosed) {
            _onSyncCompletedController.add(null);
          }
        }
      } catch (_) {}
    }
  }

  Future<void> _sendDeliveryAck(String messageId, String originalSender) async {
    try {
      final ackBytes = BlePacketCodec.encodeAck(
        messageId: messageId,
        senderId: localUsername,
        targetId: originalSender,
        statusCode: 0x01,
      );
      await bridge.sendPacket(ackBytes);
    } catch (_) {}
  }

  void dispose() {
    _stateSub?.cancel();
    _packetSub?.cancel();
    _onSyncCompletedController.close();
    _onNameConflictController.close();
    _onIncomingMessageNotifyController.close();
    _onCallSignalController.close();
    _onCallAudioController.close();
  }
}
