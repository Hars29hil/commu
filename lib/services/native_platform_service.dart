import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Bridges Flutter Dart logic with Android foreground service, push notifications,
/// custom off-grid ringtone, and low-latency native AudioTrack live call output.
class NativePlatformService {
  static const MethodChannel _channel =
      MethodChannel('com.offgrid.message_mail/mesh_platform');

  final StreamController<Map<String, dynamic>> _eventController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get eventStream => _eventController.stream;

  bool get _isAndroid {
    try {
      return !kIsWeb && Platform.isAndroid;
    } catch (_) {
      return false;
    }
  }

  NativePlatformService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNativeEvent' && call.arguments is Map) {
        final raw = Map<dynamic, dynamic>.from(call.arguments as Map);
        final map = raw.map((k, v) => MapEntry(k.toString(), v));
        if (!_eventController.isClosed) {
          _eventController.add(map);
        }
      }
    });
  }

  Future<Map<String, dynamic>?> consumePendingEvent() async {
    if (!_isAndroid) return null;
    try {
      final res = await _channel.invokeMethod('consumePendingEvent');
      if (res is Map) {
        return res.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {}
    return null;
  }

  Future<void> startMeshService({
    required String username,
    required String statusText,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('startMeshService', {
        'username': username,
        'statusText': statusText,
      });
    } catch (_) {}
  }

  Future<void> updateServiceStatus(String statusText) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('updateServiceStatus', {
        'statusText': statusText,
      });
    } catch (_) {}
  }

  Future<void> stopMeshService() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopMeshService');
    } catch (_) {}
  }

  Future<bool> isIgnoringBatteryOptimizations() async {
    if (!_isAndroid) return true;
    try {
      final res = await _channel.invokeMethod<bool>('isIgnoringBatteryOptimizations');
      return res ?? true;
    } catch (_) {
      return true;
    }
  }

  Future<void> requestIgnoreBatteryOptimizations() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
    } catch (_) {}
  }

  Future<void> showMessageNotification({
    required String chatId,
    required String title,
    required String body,
    bool isGroup = false,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('showMessageNotification', {
        'chatId': chatId,
        'title': title,
        'body': body,
        'isGroup': isGroup,
      });
    } catch (_) {}
  }

  Future<void> showIncomingCall({
    required String callId,
    required String callerId,
    required String callerName,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('showIncomingCall', {
        'callId': callId,
        'callerId': callerId,
        'callerName': callerName,
      });
    } catch (_) {}
  }

  Future<void> stopIncomingCallAlert() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopIncomingCallAlert');
    } catch (_) {}
  }

  Future<void> startRingbackTone() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('startRingbackTone');
    } catch (_) {}
  }

  Future<void> stopRingbackTone() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopRingbackTone');
    } catch (_) {}
  }

  Future<void> startCallAudioTrack({int sampleRate = 8000, bool speakerOn = false}) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('startCallAudioTrack', {
        'sampleRate': sampleRate,
        'speakerOn': speakerOn,
      });
    } catch (_) {}
  }

  Future<void> writeCallAudioPcm(Uint8List pcmBytes) async {
    if (!_isAndroid || pcmBytes.isEmpty) return;
    try {
      await _channel.invokeMethod('writeCallAudioPcm', {
        'pcm': pcmBytes,
      });
    } catch (_) {}
  }

  Future<void> setSpeakerphone(bool enabled) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('setSpeakerphone', {'enabled': enabled});
    } catch (_) {}
  }

  Future<void> stopCallAudioTrack() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopCallAudioTrack');
    } catch (_) {}
  }

  void dispose() {
    _eventController.close();
  }
}

