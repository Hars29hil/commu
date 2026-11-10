import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/message_mail.dart';
import '../protocol/ble_packet_codec.dart';
import 'database_service.dart';

/// GATT Constants for Heltec WiFi LoRa 32 V3 / ESP32-S3 Bridge
class BleGattConstants {
  static final Guid serviceUuid =
      Guid('0000A101-0000-1000-8000-00805F9B34FB');
  static final Guid charDataTx =
      Guid('0000A102-0000-1000-8000-00805F9B34FB'); // Phone -> ESP32 Write Without Response
  static final Guid charDataRx =
      Guid('0000A103-0000-1000-8000-00805F9B34FB'); // ESP32 -> Phone Notify
}

/// Connection states for the BLE Hardware Bridge.
enum BleConnectionState {
  disconnected,
  scanning,
  connecting,
  connected,
}

/// Abstract bridge allowing transparent switching between Physical BLE and Mock Engine.
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
  void dispose();
}

/// Real BLE Client implementation using flutter_blue_plus.
class FlutterBluePlusBridge implements BleHardwareBridge {
  BleConnectionState _state = BleConnectionState.disconnected;
  String? _connectedNodeName;
  int _rssi = -85;
  final int _pingLatencyMs = 24;

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
      _stateController.add(newState);
    }
  }

  void _initAutoRadar() {
    // Monitor Bluetooth Adapter state (On/Off)
    _adapterSub = FlutterBluePlus.adapterState.listen((adapterState) {
      if (adapterState == BluetoothAdapterState.on) {
        if (_state == BleConnectionState.disconnected && !_isConnecting) {
          _triggerRadarSweep();
        }
      } else {
        _setState(BleConnectionState.disconnected);
      }
    });

    // Radar heartbeat timer: checks every 4 seconds if disconnected and restarts radar scan
    _radarTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (_isAutoRadarActive &&
          _state == BleConnectionState.disconnected &&
          !_isConnecting &&
          !FlutterBluePlus.isScanningNow) {
        _triggerRadarSweep();
      }
    });
  }

  Future<void> _triggerRadarSweep() async {
    if (_state == BleConnectionState.connected || _isConnecting) return;
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
    try {
      _setState(BleConnectionState.scanning);

      _scanSub?.cancel();
      _scanSub = FlutterBluePlus.scanResults.listen((results) async {
        for (final r in results) {
          final advName = r.advertisementData.advName.toUpperCase();
          final devName = r.device.platformName.toUpperCase();
          final hasService = r.advertisementData.serviceUuids.contains(BleGattConstants.serviceUuid);
          final isMatching = hasService ||
              advName.contains('ESP32') ||
              advName.contains('DEVKIT') ||
              advName.contains('RELAY') ||
              advName.contains('HELTEC') ||
              advName.contains('NODE') ||
              advName.contains('MESSAGE') ||
              devName.contains('ESP32') ||
              devName.contains('DEVKIT') ||
              devName.contains('RELAY') ||
              devName.contains('HELTEC') ||
              devName.contains('NODE') ||
              devName.contains('MESSAGE');

          if (isMatching && !_isConnecting && _state != BleConnectionState.connected) {
            _scanSub?.cancel();
            _scanSub = null;
            await FlutterBluePlus.stopScan();
            await connectToNode(r.device.remoteId.str);
            break;
          }
        }
      });

      // Scan for 7 seconds without restrictive hardware filter to ensure 100% discovery
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

      // Listen for disconnection in real time
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
          : 'NODE-${nodeIdOrAddress.substring(max(0, nodeIdOrAddress.length - 4))}';

      // Request higher MTU for voice notes (up to 512 bytes)
      try {
        await device.requestMtu(512);
      } catch (_) {}

      // Discover Heltec V3 services
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
                    _packetRxController.add(packet);
                  } catch (_) {}
                }
              });
            }
          }
        }
      }

      // Read initial RSSI
      try {
        _rssi = await device.readRssi();
      } catch (_) {
        _rssi = -64;
      }

      // Start periodic RSSI reading while connected
      _rssiPollTimer?.cancel();
      _rssiPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (_connectedDevice != null && _state == BleConnectionState.connected) {
          try {
            _rssi = await _connectedDevice!.readRssi();
            _stateController.add(_state);
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
    Future.delayed(const Duration(seconds: 8), () {
      _isAutoRadarActive = true;
    });
  }

  @override
  Future<bool> sendPacket(Uint8List frameBytes) async {
    if (_state != BleConnectionState.connected || _txCharacteristic == null) {
      return false;
    }
    try {
      await _txCharacteristic!.write(frameBytes, withoutResponse: true);
      return true;
    } catch (_) {
      return false;
    }
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

/// High-level BLE Sync Coordinator that bridges [BleHardwareBridge] and [DatabaseService].
/// Implements Store-and-Forward:
/// - Auto-flushes local outbox when a node is in range.
/// - Saves incoming mesh packets and updates SQLite.
/// - Handles ACK packet receipts.
class BleSyncCoordinator {
  final BleHardwareBridge bridge;
  final DatabaseService db;
  String localNodeId;
  String activeRecipientId;

  StreamSubscription? _stateSub;
  StreamSubscription? _packetSub;
  bool _isFlushing = false;

  final StreamController<void> _onSyncCompletedController =
      StreamController<void>.broadcast();
  Stream<void> get onSyncCompleted => _onSyncCompletedController.stream;

  BleSyncCoordinator({
    required this.bridge,
    required this.db,
    this.localNodeId = 'NODE-P1',
    this.activeRecipientId = 'NODE-P2',
  }) {
    _stateSub = bridge.stateStream.listen((state) {
      if (state == BleConnectionState.connected) {
        // Wait 400ms to ensure GATT notifications & subscriptions are fully live
        Future.delayed(const Duration(milliseconds: 400), () async {
          await flushOutbox();
          await requestMailboxSync();
        });
      }
    });

    _packetSub = bridge.packetRxStream.listen((packet) {
      _handleIncomingPacket(packet);
    });
  }

  /// Sends a sync poll packet to the connected relay node.
  Future<void> requestMailboxSync() async {
    if (bridge.state != BleConnectionState.connected) return;
    try {
      final pollFrame = BlePacketCodec.encodePoll(senderId: localNodeId);
      await bridge.sendPacket(pollFrame);
    } catch (_) {}
  }

  /// Flushes all `PENDING_LOCAL` messages from SQLite to the connected node.
  Future<int> flushOutbox() async {
    if (bridge.state != BleConnectionState.connected || _isFlushing) {
      return 0;
    }
    _isFlushing = true;
    int flushedCount = 0;

    try {
      final pending = await db.getPendingOutbox();
      for (final msg in pending) {
        Uint8List frameBytes;
        if (msg.payloadType == PayloadType.text) {
          frameBytes = BlePacketCodec.encodeText(
            messageId: msg.id,
            recipientId: msg.recipientId,
            text: msg.textContent ?? '',
          );
        } else {
          frameBytes = BlePacketCodec.encodeVoice(
            messageId: msg.id,
            recipientId: msg.recipientId,
            audioBlob: msg.audioBlob ?? Uint8List(0),
          );
        }

        final sent = await bridge.sendPacket(frameBytes);
        if (sent) {
          // Mark as IN_TRANSIT on successful BLE relay transfer
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

  /// Handles incoming packet from RX notification.
  Future<void> _handleIncomingPacket(BlePacket packet) async {
    if (packet.isAck) {
      // End-to-end delivery ACK: status code 0x01 = DELIVERED, 0x02 = FAILED
      final statusCode = packet.payload.isNotEmpty ? packet.payload[0] : 0x01;
      final newStatus = statusCode == 0x01 ? 'DELIVERED' : 'FAILED';
      await db.updateStatusByAck(packet.messageId, newStatus);
      if (!_onSyncCompletedController.isClosed) {
        _onSyncCompletedController.add(null);
      }
    } else if (packet.isPoll) {
      // Ignore poll frame on client phone
      return;
    } else {
      // Text or Voice message mail delivered to client
      // Check if this was an outgoing message sent by our own device (prevent echo)
      final existing = await db.getMessageById(packet.messageId);
      if (existing != null) {
        if (existing.senderId == localNodeId) {
          return;
        }
      }

      // Determine sender: if recipient in packet is our local ID, sender is active conversation partner or source
      final sender = packet.recipientId == localNodeId ? activeRecipientId : packet.recipientId;

      final msg = MessageMail(
        id: packet.messageId,
        senderId: sender,
        recipientId: localNodeId,
        payloadType:
            packet.isText ? PayloadType.text : PayloadType.voiceMail,
        textContent: packet.isText ? packet.textContent : null,
        audioBlob: packet.isVoice ? packet.payload : null,
        timestamp: DateTime.now().millisecondsSinceEpoch,
        status: MessageStatus.delivered,
      );

      await db.saveIncomingMessage(msg);

      // Return an immediate Delivery ACK back to ESP32 / sender
      try {
        final ackBytes = BlePacketCodec.encodeAck(
          messageId: packet.messageId,
          recipientId: sender,
          statusCode: 0x01,
        );
        await bridge.sendPacket(ackBytes);
      } catch (_) {}

      if (!_onSyncCompletedController.isClosed) {
        _onSyncCompletedController.add(null);
      }
    }
  }

  void dispose() {
    _stateSub?.cancel();
    _packetSub?.cancel();
    _onSyncCompletedController.close();
  }
}
