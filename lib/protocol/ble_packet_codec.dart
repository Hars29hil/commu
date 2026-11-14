import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Payload type flags for Protocol v2 over BLE/LoRa bridge.
class BlePayloadFlag {
  static const int textMsg = 0x01;
  static const int voiceChunk = 0x02;
  static const int deliveryAck = 0x03;
  static const int syncPoll = 0x04;
  static const int presenceHello = 0x05;
  static const int peerDirectory = 0x06;
  static const int groupMeta = 0x07;
  static const int callSignal = 0x08;
  static const int callAudio = 0x09;
}

/// Bitmask flags in header byte [20].
class BlePacketFlags {
  static const int group = 0x01;
  static const int chunked = 0x02;
  static const int compressed = 0x04;
  static const int statusFail = 0x08;
}

/// Audio codec identifier inside voice chunks.
class VoiceCodecType {
  static const int amrNb = 0x01; // 8kHz AMR-NB .3gp (~1 KB/s)
  static const int aacLc = 0x02; // 12kbps AAC-LC .m4a (~1.5 KB/s)
  static const int wavPcm = 0x03; // Fallback WAV/PCM
}

/// Live call signaling codes (payload[0] of BlePayloadFlag.callSignal).
class CallSignalCode {
  static const int invite = 0x01;
  static const int ringing = 0x02;
  static const int accept = 0x03;
  static const int reject = 0x04;
  static const int busy = 0x05;
  static const int unavailable = 0x06;
  static const int hangup = 0x07;
  static const int voicemail = 0x08;
}

/// Peer entry parsed from a PKT_PEER_DIRECTORY packet.
class DirectoryPeerEntry {
  final String username;
  final String displayName;
  final bool isOnline;

  const DirectoryPeerEntry({
    required this.username,
    required this.displayName,
    required this.isOnline,
  });
}

/// Parsed voice chunk metadata.
class VoiceChunkData {
  final int chunkIndex;
  final int totalChunks;
  final int durationMs;
  final int codecType;
  final Uint8List chunkBytes;

  const VoiceChunkData({
    required this.chunkIndex,
    required this.totalChunks,
    required this.durationMs,
    required this.codecType,
    required this.chunkBytes,
  });
}

/// Parsed group metadata packet.
class GroupMetaData {
  final String groupId;
  final String groupName;
  final List<String> members;

  const GroupMetaData({
    required this.groupId,
    required this.groupName,
    required this.members,
  });
}

/// Parsed live call audio frame.
class CallAudioFrameData {
  final int seqNum;
  final int predictor;
  final int stepIndex;
  final int frameMs;
  final Uint8List adpcmBytes;

  const CallAudioFrameData({
    required this.seqNum,
    required this.predictor,
    required this.stepIndex,
    required this.frameMs,
    required this.adpcmBytes,
  });
}

/// Represents a Protocol v2 framed BLE/LoRa packet.
class BlePacket {
  final int version;
  final int payloadTypeFlag;
  final String messageId;
  final String senderId;
  final String targetId;
  final int flags;
  final Uint8List payload;

  const BlePacket({
    this.version = BlePacketCodec.protocolVersion,
    required this.messageId,
    required this.payloadTypeFlag,
    required this.senderId,
    required this.targetId,
    this.flags = 0,
    required this.payload,
  });

  bool get isText => payloadTypeFlag == BlePayloadFlag.textMsg;
  bool get isVoice => payloadTypeFlag == BlePayloadFlag.voiceChunk;
  bool get isAck => payloadTypeFlag == BlePayloadFlag.deliveryAck;
  bool get isPoll => payloadTypeFlag == BlePayloadFlag.syncPoll;
  bool get isPresence => payloadTypeFlag == BlePayloadFlag.presenceHello;
  bool get isDirectory => payloadTypeFlag == BlePayloadFlag.peerDirectory;
  bool get isGroupMeta => payloadTypeFlag == BlePayloadFlag.groupMeta;
  bool get isCallSignal => payloadTypeFlag == BlePayloadFlag.callSignal;
  bool get isCallAudio => payloadTypeFlag == BlePayloadFlag.callAudio;

  bool get isGroup => (flags & BlePacketFlags.group) != 0;
  bool get isCompressed => (flags & BlePacketFlags.compressed) != 0;

  /// Automatically decompresses text if FLAG_COMPRESSED is set.
  String get textContent {
    final bytes = isCompressed ? BlePacketCodec.decompressBytes(payload) : payload;
    return utf8.decode(bytes, allowMalformed: true);
  }
}

/// Binary Protocol v2 Encoder/Decoder with Adaptive Raw-Deflate Compression.
///
/// Header Layout (minimum 23 bytes):
/// - [0]      : Version (0x02)
/// - [1]      : Packet Type Flag (0x01..0x09)
/// - [2..17]  : 16-byte UUID (messageId / deviceUuid / callId)
/// - [18]     : senderLen (S, 0..24)
/// - [19]     : targetLen (T, 0..24)
/// - [20]     : flags bitmask
/// - [21..22] : payloadLen (2-byte uint16 Big Endian)
/// - [23..23+S-1]     : senderId UTF-8
/// - [23+S..23+S+T-1] : targetId UTF-8
/// - [23+S+T..N]      : payload bytes
class BlePacketCodec {
  static const int protocolVersion = 0x02;
  static const int minHeaderLength = 23;
  static const int maxIdLength = 24;
  static const int maxVoiceChunkBytes = 360;

  static final ZLibCodec _rawDeflate = ZLibCodec(raw: true, level: 9);

  /// Normalizes a display name into a clean lowercase unique handle (max 24 ASCII bytes).
  static String normalizeUsername(String input) {
    final lower = input.trim().toLowerCase();
    final cleaned = lower
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'[^a-z0-9_]'), '');
    if (cleaned.length <= maxIdLength) return cleaned;
    return cleaned.substring(0, maxIdLength);
  }

  /// Compresses bytes using Raw Deflate only when it strictly saves space.
  static ({Uint8List bytes, bool compressed}) compressAdaptive(Uint8List raw) {
    if (raw.length < 16) {
      return (bytes: raw, compressed: false);
    }
    try {
      final deflated = Uint8List.fromList(_rawDeflate.encode(raw));
      if (deflated.length < raw.length) {
        return (bytes: deflated, compressed: true);
      }
    } catch (_) {}
    return (bytes: raw, compressed: false);
  }

  static Uint8List decompressBytes(Uint8List deflated) {
    try {
      return Uint8List.fromList(_rawDeflate.decode(deflated));
    } catch (_) {
      return deflated;
    }
  }

  /// Encodes a [BlePacket] into Protocol v2 binary bytes.
  static Uint8List encode(BlePacket packet) {
    final uuidBytes = _uuidToBytes(packet.messageId);
    final senderBytes = _idToBytes(packet.senderId);
    final targetBytes = _idToBytes(packet.targetId);
    final payloadBytes = packet.payload;
    final payloadLen = payloadBytes.length;

    if (payloadLen > 65535) {
      throw ArgumentError('Payload exceeds 65535 bytes');
    }

    final headerLen = minHeaderLength + senderBytes.length + targetBytes.length;
    final buffer = Uint8List(headerLen + payloadLen);
    final byteData = ByteData.sublistView(buffer);

    buffer[0] = packet.version & 0xFF;
    buffer[1] = packet.payloadTypeFlag & 0xFF;
    buffer.setRange(2, 18, uuidBytes);
    buffer[18] = senderBytes.length;
    buffer[19] = targetBytes.length;
    buffer[20] = packet.flags & 0xFF;
    byteData.setUint16(21, payloadLen, Endian.big);

    int offset = minHeaderLength;
    if (senderBytes.isNotEmpty) {
      buffer.setRange(offset, offset + senderBytes.length, senderBytes);
      offset += senderBytes.length;
    }
    if (targetBytes.isNotEmpty) {
      buffer.setRange(offset, offset + targetBytes.length, targetBytes);
      offset += targetBytes.length;
    }
    if (payloadLen > 0) {
      buffer.setRange(offset, offset + payloadLen, payloadBytes);
    }

    return buffer;
  }

  /// Encodes a text message with adaptive Raw-Deflate compression.
  static Uint8List encodeText({
    required String messageId,
    required String senderId,
    required String targetId,
    required String text,
    bool isGroup = false,
  }) {
    final raw = Uint8List.fromList(utf8.encode(text));
    final comp = compressAdaptive(raw);
    int flags = isGroup ? BlePacketFlags.group : 0;
    if (comp.compressed) flags |= BlePacketFlags.compressed;

    return encode(
      BlePacket(
        messageId: messageId,
        payloadTypeFlag: BlePayloadFlag.textMsg,
        senderId: senderId,
        targetId: targetId,
        flags: flags,
        payload: comp.bytes,
      ),
    );
  }

  /// Splits a compressed voice note blob into BLE-safe chunk packets (<= 440 bytes each).
  static List<Uint8List> encodeVoiceChunks({
    required String messageId,
    required String senderId,
    required String targetId,
    required Uint8List audioBlob,
    required int durationMs,
    required int codecType,
    bool isGroup = false,
  }) {
    final totalBytes = audioBlob.length;
    final totalChunks = totalBytes == 0
        ? 1
        : ((totalBytes + maxVoiceChunkBytes - 1) / maxVoiceChunkBytes).floor();

    final clampedDuration = durationMs.clamp(0, 65535);
    int flags = BlePacketFlags.chunked | (isGroup ? BlePacketFlags.group : 0);

    final frames = <Uint8List>[];
    for (int idx = 0; idx < totalChunks; idx++) {
      final start = idx * maxVoiceChunkBytes;
      final end = (start + maxVoiceChunkBytes) > totalBytes
          ? totalBytes
          : (start + maxVoiceChunkBytes);
      final slice = totalBytes == 0 ? Uint8List(0) : audioBlob.sublist(start, end);

      final payload = Uint8List(7 + slice.length);
      final bd = ByteData.sublistView(payload);
      bd.setUint16(0, idx, Endian.big);
      bd.setUint16(2, totalChunks, Endian.big);
      bd.setUint16(4, clampedDuration, Endian.big);
      payload[6] = codecType & 0xFF;
      if (slice.isNotEmpty) {
        payload.setRange(7, 7 + slice.length, slice);
      }

      frames.add(
        encode(
          BlePacket(
            messageId: messageId,
            payloadTypeFlag: BlePayloadFlag.voiceChunk,
            senderId: senderId,
            targetId: targetId,
            flags: flags,
            payload: payload,
          ),
        ),
      );
    }
    return frames;
  }

  static VoiceChunkData decodeVoiceChunk(Uint8List payload) {
    if (payload.length < 7) {
      throw const FormatException('Voice chunk payload too short');
    }
    final bd = ByteData.sublistView(payload);
    return VoiceChunkData(
      chunkIndex: bd.getUint16(0, Endian.big),
      totalChunks: bd.getUint16(2, Endian.big),
      durationMs: bd.getUint16(4, Endian.big),
      codecType: payload[6],
      chunkBytes: payload.sublist(7),
    );
  }

  static Uint8List encodeAck({
    required String messageId,
    required String senderId,
    required String targetId,
    int statusCode = 0x01,
  }) {
    return encode(
      BlePacket(
        messageId: messageId,
        payloadTypeFlag: BlePayloadFlag.deliveryAck,
        senderId: senderId,
        targetId: targetId,
        payload: Uint8List.fromList([statusCode]),
      ),
    );
  }

  static Uint8List encodePoll({required String senderId}) {
    return encode(
      BlePacket(
        messageId: '00000000-0000-0000-0000-000000000000',
        payloadTypeFlag: BlePayloadFlag.syncPoll,
        senderId: senderId,
        targetId: 'RELAY',
        payload: Uint8List(0),
      ),
    );
  }

  static Uint8List encodePresenceHello({
    required String deviceUuid,
    required String username,
    required String displayName,
  }) {
    final nameBytes = Uint8List.fromList(utf8.encode(displayName.trim()));
    final trimmed = nameBytes.length > 32 ? nameBytes.sublist(0, 32) : nameBytes;
    return encode(
      BlePacket(
        messageId: deviceUuid,
        payloadTypeFlag: BlePayloadFlag.presenceHello,
        senderId: username,
        targetId: 'RELAY',
        payload: trimmed,
      ),
    );
  }

  /// Encodes group creation/sync payload (binary compact, readable by ESP32).
  static Uint8List encodeGroupMeta({
    required String messageId,
    required String senderId,
    required String groupId,
    required String groupName,
    required List<String> members,
  }) {
    final gNameBytes = utf8.encode(groupName.trim());
    final gLen = gNameBytes.length.clamp(1, 32);
    final builder = BytesBuilder();
    builder.addByte(gLen);
    builder.add(gNameBytes.sublist(0, gLen));

    final cleanMembers = members
        .map((m) => normalizeUsername(m))
        .where((m) => m.isNotEmpty)
        .toSet()
        .toList();
    builder.addByte(cleanMembers.length.clamp(0, 16));
    for (final m in cleanMembers.take(16)) {
      final mb = _idToBytes(m);
      builder.addByte(mb.length);
      builder.add(mb);
    }

    return encode(
      BlePacket(
        messageId: messageId,
        payloadTypeFlag: BlePayloadFlag.groupMeta,
        senderId: senderId,
        targetId: groupId,
        flags: BlePacketFlags.group,
        payload: builder.toBytes(),
      ),
    );
  }

  static GroupMetaData decodeGroupMeta(String groupId, Uint8List payload) {
    if (payload.length < 2) {
      throw const FormatException('Invalid group meta payload');
    }
    int pos = 0;
    final nameLen = payload[pos++];
    if (pos + nameLen >= payload.length) {
      throw const FormatException('Truncated group name');
    }
    final groupName = utf8.decode(payload.sublist(pos, pos + nameLen), allowMalformed: true);
    pos += nameLen;

    final memberCount = payload[pos++];
    final members = <String>[];
    for (int i = 0; i < memberCount && pos < payload.length; i++) {
      final mLen = payload[pos++];
      if (pos + mLen > payload.length) break;
      final m = utf8.decode(payload.sublist(pos, pos + mLen), allowMalformed: true);
      if (m.isNotEmpty) members.add(m);
      pos += mLen;
    }

    return GroupMetaData(
      groupId: groupId,
      groupName: groupName,
      members: members,
    );
  }

  static ({int page, int totalPages, List<DirectoryPeerEntry> peers}) decodePeerDirectory(
    Uint8List payload,
  ) {
    if (payload.length < 3) {
      return (page: 0, totalPages: 1, peers: const []);
    }
    int pos = 0;
    final page = payload[pos++];
    final totalPages = payload[pos++];
    final count = payload[pos++];
    final entries = <DirectoryPeerEntry>[];

    for (int i = 0; i < count && pos < payload.length; i++) {
      final uLen = payload[pos++];
      if (pos + uLen >= payload.length) break;
      final username = utf8.decode(payload.sublist(pos, pos + uLen), allowMalformed: true);
      pos += uLen;

      final dLen = payload[pos++];
      if (pos + dLen >= payload.length) break;
      final displayName = utf8.decode(payload.sublist(pos, pos + dLen), allowMalformed: true);
      pos += dLen;

      if (pos >= payload.length) break;
      final isOnline = payload[pos++] == 0x01;

      if (username.isNotEmpty) {
        entries.add(DirectoryPeerEntry(
          username: username,
          displayName: displayName.isNotEmpty ? displayName : username,
          isOnline: isOnline,
        ));
      }
    }

    return (page: page, totalPages: totalPages, peers: entries);
  }

  static Uint8List encodeCallSignal({
    required String callId,
    required String senderId,
    required String targetId,
    required int signalCode,
  }) {
    return encode(
      BlePacket(
        messageId: callId,
        payloadTypeFlag: BlePayloadFlag.callSignal,
        senderId: senderId,
        targetId: targetId,
        payload: Uint8List.fromList([signalCode & 0xFF]),
      ),
    );
  }

  static Uint8List encodeCallAudio({
    required String callId,
    required String senderId,
    required String targetId,
    required int seqNum,
    required int predictor,
    required int stepIndex,
    required int frameMs,
    required Uint8List adpcmBytes,
  }) {
    final payload = Uint8List(6 + adpcmBytes.length);
    final bd = ByteData.sublistView(payload);
    bd.setUint16(0, seqNum & 0xFFFF, Endian.big);
    bd.setInt16(2, predictor.clamp(-32768, 32767), Endian.big);
    payload[4] = stepIndex & 0xFF;
    payload[5] = frameMs & 0xFF;
    if (adpcmBytes.isNotEmpty) {
      payload.setRange(6, 6 + adpcmBytes.length, adpcmBytes);
    }

    return encode(
      BlePacket(
        messageId: callId,
        payloadTypeFlag: BlePayloadFlag.callAudio,
        senderId: senderId,
        targetId: targetId,
        flags: BlePacketFlags.compressed,
        payload: payload,
      ),
    );
  }

  static CallAudioFrameData decodeCallAudio(Uint8List payload) {
    if (payload.length < 6) {
      throw const FormatException('Call audio payload too short');
    }
    final bd = ByteData.sublistView(payload);
    return CallAudioFrameData(
      seqNum: bd.getUint16(0, Endian.big),
      predictor: bd.getInt16(2, Endian.big),
      stepIndex: payload[4],
      frameMs: payload[5],
      adpcmBytes: payload.sublist(6),
    );
  }

  /// Decodes raw Protocol v2 bytes into a [BlePacket].
  static BlePacket decode(Uint8List rawBytes) {
    if (rawBytes.length < minHeaderLength) {
      throw FormatException(
        'Packet too short: ${rawBytes.length} bytes (minimum $minHeaderLength bytes)',
      );
    }
    if (rawBytes[0] != protocolVersion) {
      throw FormatException('Unsupported protocol version: ${rawBytes[0]}');
    }

    final byteData = ByteData.sublistView(rawBytes);
    final payloadType = rawBytes[1];
    final messageId = _bytesToUuid(rawBytes.sublist(2, 18));
    final senderLen = rawBytes[18];
    final targetLen = rawBytes[19];
    final flags = rawBytes[20];
    final payloadLength = byteData.getUint16(21, Endian.big);

    final expectedTotal = minHeaderLength + senderLen + targetLen + payloadLength;
    if (rawBytes.length < expectedTotal) {
      throw FormatException(
        'Truncated packet: expected $expectedTotal bytes, got ${rawBytes.length}',
      );
    }

    int offset = minHeaderLength;
    final senderId = senderLen > 0
        ? utf8.decode(rawBytes.sublist(offset, offset + senderLen), allowMalformed: true)
        : '';
    offset += senderLen;

    final targetId = targetLen > 0
        ? utf8.decode(rawBytes.sublist(offset, offset + targetLen), allowMalformed: true)
        : '';
    offset += targetLen;

    final payload = rawBytes.sublist(offset, offset + payloadLength);

    return BlePacket(
      version: rawBytes[0],
      messageId: messageId,
      payloadTypeFlag: payloadType,
      senderId: senderId,
      targetId: targetId,
      flags: flags,
      payload: payload,
    );
  }

  static Uint8List _idToBytes(String id) {
    final utf = utf8.encode(id.trim());
    if (utf.length <= maxIdLength) return Uint8List.fromList(utf);
    return Uint8List.fromList(utf.sublist(0, maxIdLength));
  }

  static Uint8List _uuidToBytes(String uuid) {
    final clean = uuid.replaceAll('-', '').trim();
    if (clean.length != 32) {
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

  static String _bytesToUuid(Uint8List bytes) {
    if (bytes.length != 16) {
      throw ArgumentError('UUID bytes must be exactly 16 bytes');
    }
    final hexStr = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return '${hexStr.substring(0, 8)}-'
        '${hexStr.substring(8, 12)}-'
        '${hexStr.substring(12, 16)}-'
        '${hexStr.substring(16, 20)}-'
        '${hexStr.substring(20, 32)}';
  }
}
