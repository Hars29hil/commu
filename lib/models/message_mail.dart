import 'dart:typed_data';
import '../protocol/ble_packet_codec.dart';

/// Payload type of an off-grid message or call log.
enum PayloadType {
  text('text'),
  voiceMail('voice_mail'),
  callLog('call_log');

  final String value;
  const PayloadType(this.value);

  static PayloadType fromString(String val) {
    switch (val) {
      case 'voice_mail':
        return PayloadType.voiceMail;
      case 'call_log':
        return PayloadType.callLog;
      case 'text':
      default:
        return PayloadType.text;
    }
  }
}

/// Lifecycle status of an off-grid message.
enum MessageStatus {
  pendingLocal('PENDING_LOCAL'),
  inTransit('IN_TRANSIT'),
  delivered('DELIVERED'),
  failed('FAILED');

  final String value;
  const MessageStatus(this.value);

  static MessageStatus fromString(String val) {
    switch (val) {
      case 'IN_TRANSIT':
        return MessageStatus.inTransit;
      case 'DELIVERED':
        return MessageStatus.delivered;
      case 'FAILED':
        return MessageStatus.failed;
      case 'PENDING_LOCAL':
      default:
        return MessageStatus.pendingLocal;
    }
  }
}

/// Local device user identity stored permanently in SQLite.
class LocalProfile {
  final String deviceUuid;
  final String username;
  final String displayName;
  final bool isVerifiedOnRelay;

  const LocalProfile({
    required this.deviceUuid,
    required this.username,
    required this.displayName,
    this.isVerifiedOnRelay = false,
  });

  Map<String, dynamic> toMap() => {
        'id': 1,
        'device_uuid': deviceUuid,
        'username': username,
        'display_name': displayName,
        'is_verified': isVerifiedOnRelay ? 1 : 0,
      };

  factory LocalProfile.fromMap(Map<String, dynamic> map) => LocalProfile(
        deviceUuid: map['device_uuid'] as String,
        username: map['username'] as String,
        displayName: map['display_name'] as String,
        isVerifiedOnRelay: ((map['is_verified'] as int?) ?? 0) == 1,
      );

  LocalProfile copyWith({
    String? deviceUuid,
    String? username,
    String? displayName,
    bool? isVerifiedOnRelay,
  }) {
    return LocalProfile(
      deviceUuid: deviceUuid ?? this.deviceUuid,
      username: username ?? this.username,
      displayName: displayName ?? this.displayName,
      isVerifiedOnRelay: isVerifiedOnRelay ?? this.isVerifiedOnRelay,
    );
  }
}

/// Discovered peer user on the off-grid mesh relay.
class PeerUser {
  final String username;
  final String displayName;
  final bool isOnline;
  final int lastSeen;

  const PeerUser({
    required this.username,
    required this.displayName,
    required this.isOnline,
    required this.lastSeen,
  });

  Map<String, dynamic> toMap() => {
        'username': username,
        'display_name': displayName,
        'is_online': isOnline ? 1 : 0,
        'last_seen': lastSeen,
      };

  factory PeerUser.fromMap(Map<String, dynamic> map) => PeerUser(
        username: map['username'] as String,
        displayName: map['display_name'] as String,
        isOnline: ((map['is_online'] as int?) ?? 0) == 1,
        lastSeen: (map['last_seen'] as int?) ?? 0,
      );
}

/// Group conversation metadata synchronized over the relay.
class ChatGroup {
  final String groupId;
  final String groupName;
  final String createdBy;
  final int createdAt;
  final List<String> members;

  const ChatGroup({
    required this.groupId,
    required this.groupName,
    required this.createdBy,
    required this.createdAt,
    required this.members,
  });

  Map<String, dynamic> toMap() => {
        'group_id': groupId,
        'group_name': groupName,
        'created_by': createdBy,
        'created_at': createdAt,
      };

  factory ChatGroup.fromMap(Map<String, dynamic> map, List<String> members) =>
      ChatGroup(
        groupId: map['group_id'] as String,
        groupName: map['group_name'] as String,
        createdBy: map['created_by'] as String,
        createdAt: map['created_at'] as int,
        members: members,
      );
}

/// WhatsApp-style home chat row combining 1-to-1 and group chats.
class ChatSummary {
  final String chatId;
  final String title;
  final bool isGroup;
  final bool isOnline;
  final int memberCount;
  final MessageMail? lastMessage;
  final int unreadCount;
  final int lastActivityMs;

  const ChatSummary({
    required this.chatId,
    required this.title,
    required this.isGroup,
    required this.isOnline,
    required this.memberCount,
    this.lastMessage,
    this.unreadCount = 0,
    required this.lastActivityMs,
  });
}

/// Call state machine phases.
enum CallPhase {
  idle,
  calling,
  ringing,
  incoming,
  connected,
  unansweredPrompt,
  recordingVoicemail,
}

class CallSessionState {
  final String? callId;
  final String? peerUsername;
  final String? peerDisplayName;
  final CallPhase phase;
  final int? connectedAtMs;
  final bool isMuted;
  final bool isSpeakerOn;
  final String? endReason;

  const CallSessionState({
    this.callId,
    this.peerUsername,
    this.peerDisplayName,
    this.phase = CallPhase.idle,
    this.connectedAtMs,
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.endReason,
  });

  bool get isActive => phase != CallPhase.idle;

  CallSessionState copyWith({
    String? callId,
    String? peerUsername,
    String? peerDisplayName,
    CallPhase? phase,
    int? connectedAtMs,
    bool? isMuted,
    bool? isSpeakerOn,
    String? endReason,
  }) {
    return CallSessionState(
      callId: callId ?? this.callId,
      peerUsername: peerUsername ?? this.peerUsername,
      peerDisplayName: peerDisplayName ?? this.peerDisplayName,
      phase: phase ?? this.phase,
      connectedAtMs: connectedAtMs ?? this.connectedAtMs,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      endReason: endReason ?? this.endReason,
    );
  }
}

/// Persisted message record in SQLite (`message_mail` table).
class MessageMail {
  final String id;
  final String chatId;
  final String senderId;
  final String recipientId;
  final bool isGroup;
  final PayloadType payloadType;
  final String? textContent;
  final Uint8List? audioBlob;
  final int durationMs;
  final int codecType;
  final bool isRead;
  final int timestamp;
  final int retryCount;
  final MessageStatus status;

  const MessageMail({
    required this.id,
    String? chatId,
    required this.senderId,
    required this.recipientId,
    this.isGroup = false,
    required this.payloadType,
    this.textContent,
    this.audioBlob,
    this.durationMs = 0,
    this.codecType = VoiceCodecType.amrNb,
    this.isRead = true,
    required this.timestamp,
    this.retryCount = 0,
    required this.status,
  }) : chatId = chatId ?? recipientId;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'chat_id': chatId,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'is_group': isGroup ? 1 : 0,
      'payload_type': payloadType.value,
      'text_content': textContent,
      'audio_blob': audioBlob,
      'duration_ms': durationMs,
      'codec_type': codecType,
      'is_read': isRead ? 1 : 0,
      'timestamp': timestamp,
      'retry_count': retryCount,
      'status': status.value,
    };
  }

  factory MessageMail.fromMap(Map<String, dynamic> map) {
    Uint8List? blob;
    if (map['audio_blob'] != null) {
      if (map['audio_blob'] is Uint8List) {
        blob = map['audio_blob'] as Uint8List;
      } else if (map['audio_blob'] is List) {
        blob = Uint8List.fromList((map['audio_blob'] as List).cast<int>());
      }
    }

    final recipient = map['recipient_id'] as String;
    return MessageMail(
      id: map['id'] as String,
      chatId: (map['chat_id'] as String?) ?? recipient,
      senderId: map['sender_id'] as String,
      recipientId: recipient,
      isGroup: ((map['is_group'] as int?) ?? 0) == 1,
      payloadType: PayloadType.fromString(map['payload_type'] as String),
      textContent: map['text_content'] as String?,
      audioBlob: blob,
      durationMs: (map['duration_ms'] as int?) ?? 0,
      codecType: (map['codec_type'] as int?) ?? VoiceCodecType.amrNb,
      isRead: ((map['is_read'] as int?) ?? 1) == 1,
      timestamp: map['timestamp'] as int,
      retryCount: (map['retry_count'] as int?) ?? 0,
      status: MessageStatus.fromString(map['status'] as String),
    );
  }

  MessageMail copyWith({
    String? id,
    String? chatId,
    String? senderId,
    String? recipientId,
    bool? isGroup,
    PayloadType? payloadType,
    String? textContent,
    Uint8List? audioBlob,
    int? durationMs,
    int? codecType,
    bool? isRead,
    int? timestamp,
    int? retryCount,
    MessageStatus? status,
  }) {
    return MessageMail(
      id: id ?? this.id,
      chatId: chatId ?? this.chatId,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      isGroup: isGroup ?? this.isGroup,
      payloadType: payloadType ?? this.payloadType,
      textContent: textContent ?? this.textContent,
      audioBlob: audioBlob ?? this.audioBlob,
      durationMs: durationMs ?? this.durationMs,
      codecType: codecType ?? this.codecType,
      isRead: isRead ?? this.isRead,
      timestamp: timestamp ?? this.timestamp,
      retryCount: retryCount ?? this.retryCount,
      status: status ?? this.status,
    );
  }
}
