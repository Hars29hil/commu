import 'dart:typed_data';

/// Represents the payload type of an off-grid mail packet.
enum PayloadType {
  text('text'),
  voiceMail('voice_mail');

  final String value;
  const PayloadType(this.value);

  static PayloadType fromString(String val) {
    if (val == 'voice_mail') return PayloadType.voiceMail;
    return PayloadType.text;
  }
}

/// Represents the status lifecycle of an off-grid message mail.
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

/// Data model matching the SQLite schema:
/// id TEXT PRIMARY KEY,
/// sender_id TEXT NOT NULL,
/// recipient_id TEXT NOT NULL,
/// payload_type TEXT NOT NULL CHECK(payload_type IN ('text', 'voice_mail')),
/// text_content TEXT,
/// audio_blob BLOB,
/// timestamp INTEGER NOT NULL,
/// retry_count INTEGER DEFAULT 0,
/// status TEXT NOT NULL CHECK(status IN ('PENDING_LOCAL', 'IN_TRANSIT', 'DELIVERED', 'FAILED'))
class MessageMail {
  final String id;
  final String senderId;
  final String recipientId;
  final PayloadType payloadType;
  final String? textContent;
  final Uint8List? audioBlob;
  final int timestamp;
  final int retryCount;
  final MessageStatus status;

  const MessageMail({
    required this.id,
    required this.senderId,
    required this.recipientId,
    required this.payloadType,
    this.textContent,
    this.audioBlob,
    required this.timestamp,
    this.retryCount = 0,
    required this.status,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'sender_id': senderId,
      'recipient_id': recipientId,
      'payload_type': payloadType.value,
      'text_content': textContent,
      'audio_blob': audioBlob,
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

    return MessageMail(
      id: map['id'] as String,
      senderId: map['sender_id'] as String,
      recipientId: map['recipient_id'] as String,
      payloadType: PayloadType.fromString(map['payload_type'] as String),
      textContent: map['text_content'] as String?,
      audioBlob: blob,
      timestamp: map['timestamp'] as int,
      retryCount: (map['retry_count'] as int?) ?? 0,
      status: MessageStatus.fromString(map['status'] as String),
    );
  }

  MessageMail copyWith({
    String? id,
    String? senderId,
    String? recipientId,
    PayloadType? payloadType,
    String? textContent,
    Uint8List? audioBlob,
    int? timestamp,
    int? retryCount,
    MessageStatus? status,
  }) {
    return MessageMail(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      recipientId: recipientId ?? this.recipientId,
      payloadType: payloadType ?? this.payloadType,
      textContent: textContent ?? this.textContent,
      audioBlob: audioBlob ?? this.audioBlob,
      timestamp: timestamp ?? this.timestamp,
      retryCount: retryCount ?? this.retryCount,
      status: status ?? this.status,
    );
  }

  @override
  String toString() {
    return 'MessageMail(id: $id, from: $senderId, to: $recipientId, type: ${payloadType.value}, status: ${status.value}, time: $timestamp)';
  }
}

