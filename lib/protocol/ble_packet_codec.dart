import 'dart:convert';
import 'dart:typed_data';

/// Flags for payload types over the LoRa/BLE bridge.
class BlePayloadFlag {
  static const int utf8Text = 0x01;
  static const int voiceChunk = 0x02;
  static const int deliveryAck = 0x03;
  static const int syncPoll = 0x04;
}

/// Represents a framed BLE/LoRa message packet.
class BlePacket {
  final String messageId; // UUID representation
  final int payloadTypeFlag; // 0x01, 0x02, 0x03, 0x04
  final String recipientId; // 8-byte representation
  final Uint8List payload; // Raw payload bytes

  const BlePacket({
    required this.messageId,
    required this.payloadTypeFlag,
    required this.recipientId,
    required this.payload,
  });

  bool get isText => payloadTypeFlag == BlePayloadFlag.utf8Text;
  bool get isVoice => payloadTypeFlag == BlePayloadFlag.voiceChunk;
  bool get isAck => payloadTypeFlag == BlePayloadFlag.deliveryAck;
  bool get isPoll => payloadTypeFlag == BlePayloadFlag.syncPoll;

  String get textContent => utf8.decode(payload, allowMalformed: true);
}

/// Encoder and Decoder for the BLE Hardware Bridge Protocol.
///
/// Binary Layout:
/// - [0..15]  : 16-byte UUID (Message Identifier)
/// - [16]     : Payload Type Flag (0x01 = Text, 0x02 = Voice, 0x03 = ACK)
/// - [17..24] : 8-byte Recipient Node / Device ID
/// - [25..26] : 2-byte Payload Length (Big Endian)
/// - [27..N]  : Payload bytes
class BlePacketCodec {
  static const int headerLength = 27;

  /// Encodes a [BlePacket] into a raw binary frame.
  static Uint8List encode(BlePacket packet) {
    final uuidBytes = _uuidToBytes(packet.messageId);
    final recipientBytes = _recipientToBytes(packet.recipientId);
    final payloadBytes = packet.payload;
    final payloadLength = payloadBytes.length;

    if (payloadLength > 65535) {
      throw ArgumentError('Payload exceeds maximum length of 65535 bytes');
    }

    final totalLength = headerLength + payloadLength;
    final buffer = Uint8List(totalLength);
    final byteData = ByteData.sublistView(buffer);

    // [0..15]: 16-byte UUID
    buffer.setRange(0, 16, uuidBytes);

    // [16]: Payload Type Flag
    buffer[16] = packet.payloadTypeFlag & 0xFF;

    // [17..24]: 8-byte Recipient ID
    buffer.setRange(17, 25, recipientBytes);

    // [25..26]: 2-byte Payload Length (Big Endian)
    byteData.setUint16(25, payloadLength, Endian.big);

    // [27..N]: Payload bytes
    if (payloadLength > 0) {
      buffer.setRange(27, totalLength, payloadBytes);
    }

    return buffer;
  }

  /// Helper to encode a text message into a BLE packet frame.
  static Uint8List encodeText({
    required String messageId,
    required String recipientId,
    required String text,
  }) {
    final payload = Uint8List.fromList(utf8.encode(text));
    return encode(
      BlePacket(
        messageId: messageId,
        payloadTypeFlag: BlePayloadFlag.utf8Text,
        recipientId: recipientId,
        payload: payload,
      ),
    );
  }

  /// Helper to encode a voice mail chunk into a BLE packet frame.
  static Uint8List encodeVoice({
    required String messageId,
    required String recipientId,
    required Uint8List audioBlob,
  }) {
    return encode(
      BlePacket(
        messageId: messageId,
        payloadTypeFlag: BlePayloadFlag.voiceChunk,
        recipientId: recipientId,
        payload: audioBlob,
      ),
    );
  }

  /// Helper to encode a delivery ACK into a BLE packet frame.
  static Uint8List encodeAck({
    required String messageId,
    required String recipientId,
    int statusCode = 0x01, // 0x01 = DELIVERED, 0x02 = FAILED
  }) {
    return encode(
      BlePacket(
        messageId: messageId,
        payloadTypeFlag: BlePayloadFlag.deliveryAck,
        recipientId: recipientId,
        payload: Uint8List.fromList([statusCode]),
      ),
    );
  }

  /// Helper to encode a SYNC / POLL mailbox frame.
  static Uint8List encodePoll({
    required String senderId,
  }) {
    return encode(
      BlePacket(
        messageId: '00000000-0000-0000-0000-000000000000',
        payloadTypeFlag: BlePayloadFlag.syncPoll,
        recipientId: senderId,
        payload: Uint8List(0),
      ),
    );
  }

  /// Decodes raw binary bytes received over BLE into a [BlePacket].
  static BlePacket decode(Uint8List rawBytes) {
    if (rawBytes.length < headerLength) {
      throw FormatException(
        'Packet too short: ${rawBytes.length} bytes (minimum $headerLength bytes required)',
      );
    }

    final byteData = ByteData.sublistView(rawBytes);

    // [0..15]: 16-byte UUID
    final uuidBytes = rawBytes.sublist(0, 16);
    final messageId = _bytesToUuid(uuidBytes);

    // [16]: Payload Type Flag
    final payloadType = rawBytes[16];

    // [17..24]: 8-byte Recipient ID
    final recipientBytes = rawBytes.sublist(17, 25);
    final recipientId = _bytesToRecipient(recipientBytes);

    // [25..26]: 2-byte Payload Length (Big Endian)
    final payloadLength = byteData.getUint16(25, Endian.big);

    final expectedTotal = headerLength + payloadLength;
    if (rawBytes.length < expectedTotal) {
      throw FormatException(
        'Truncated packet: expected $expectedTotal bytes, got ${rawBytes.length}',
      );
    }

    // [27..N]: Payload bytes
    final payload = rawBytes.sublist(27, expectedTotal);

    return BlePacket(
      messageId: messageId,
      payloadTypeFlag: payloadType,
      recipientId: recipientId,
      payload: payload,
    );
  }

  /// Converts a UUID string (canonical or unhyphenated) to 16 raw bytes.
  static Uint8List _uuidToBytes(String uuid) {
    final clean = uuid.replaceAll('-', '').trim();
    if (clean.length != 32) {
      // If it's an arbitrary non-UUID string, pad or hash it into 16 bytes deterministically
      final bytes = Uint8List(16);
      final utf = utf8.encode(uuid);
      for (int i = 0; i < 16; i++) {
        bytes[i] = i < utf.length ? utf[i] : 0;
      }
      return bytes;
    }

    final result = Uint8List(16);
    for (int i = 0; i < 16; i++) {
      final byteHex = clean.substring(i * 2, i * 2 + 2);
      result[i] = int.parse(byteHex, radix: 16);
    }
    return result;
  }

  /// Converts 16 raw bytes to canonical UUID string `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`.
  static String _bytesToUuid(Uint8List bytes) {
    if (bytes.length != 16) {
      throw ArgumentError('UUID bytes must be exactly 16 bytes');
    }
    final hexStr = bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join('');
    // Canonical format: 8-4-4-4-12
    return '${hexStr.substring(0, 8)}-'
        '${hexStr.substring(8, 12)}-'
        '${hexStr.substring(12, 16)}-'
        '${hexStr.substring(16, 20)}-'
        '${hexStr.substring(20, 32)}';
  }

  /// Converts a recipient string (e.g. 'NODE-P01') into exactly 8 bytes.
  static Uint8List _recipientToBytes(String recipient) {
    final result = Uint8List(8);
    final utf = utf8.encode(recipient.trim());
    for (int i = 0; i < 8; i++) {
      result[i] = i < utf.length ? utf[i] : 0;
    }
    return result;
  }

  /// Converts 8 bytes into a recipient string, stripping trailing null bytes.
  static String _bytesToRecipient(Uint8List bytes) {
    final endIndex = bytes.indexOf(0);
    final length = endIndex == -1 ? bytes.length : endIndex;
    return utf8.decode(bytes.sublist(0, length), allowMalformed: true).trim();
  }
}

