import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:message_mail/protocol/ble_packet_codec.dart';
import 'package:message_mail/services/ima_adpcm_codec.dart';

void main() {
  const testUuid = 'f47ac10b-58cc-4372-a567-0e02b2c3d479';
  const callUuid = '12345678-90ab-cdef-1234-567890abcdef';

  group('Protocol v2 BlePacketCodec & Compression Tests', () {
    test('normalizeUsername sanitizes display names into clean ASCII handles', () {
      expect(BlePacketCodec.normalizeUsername('Harshil Patel'), equals('harshil_patel'));
      expect(BlePacketCodec.normalizeUsername('  Taksh#99!!  '), equals('taksh99'));
      expect(
        BlePacketCodec.normalizeUsername('VeryLongUsernameExceedingTwentyFourCharacters').length,
        equals(BlePacketCodec.maxIdLength),
      );
    });

    test('Short text skips compression and roundtrips cleanly with sender & target', () {
      final encoded = BlePacketCodec.encodeText(
        messageId: testUuid,
        senderId: 'harshil',
        targetId: 'taksh',
        text: 'Hi Taksh!',
      );

      final decoded = BlePacketCodec.decode(encoded);
      expect(decoded.version, equals(BlePacketCodec.protocolVersion));
      expect(decoded.isText, isTrue);
      expect(decoded.isCompressed, isFalse);
      expect(decoded.isGroup, isFalse);
      expect(decoded.messageId, equals(testUuid));
      expect(decoded.senderId, equals('harshil'));
      expect(decoded.targetId, equals('taksh'));
      expect(decoded.textContent, equals('Hi Taksh!'));
    });

    test('Repetitive longer text enables Raw-Deflate compression and shrinks packet size', () {
      const longMsg = 'Meet at Base Camp Gate 2 at 18:30. '
          'Bring extra water, flashlight, and spare batteries! '
          'Meet at Base Camp Gate 2 at 18:30. Check in when ready.';
      final encoded = BlePacketCodec.encodeText(
        messageId: testUuid,
        senderId: 'harshil',
        targetId: 'g_trek123',
        text: longMsg,
        isGroup: true,
      );

      final rawUtf8Length = longMsg.length;
      final headerLen = BlePacketCodec.minHeaderLength + 'harshil'.length + 'g_trek123'.length;
      expect(encoded.length, lessThan(headerLen + rawUtf8Length));

      final decoded = BlePacketCodec.decode(encoded);
      expect(decoded.isCompressed, isTrue);
      expect(decoded.isGroup, isTrue);
      expect(decoded.textContent, equals(longMsg));
    });

    test('Voice chunks split large audio blobs into <= 440 byte BLE packets and reassemble', () {
      final fakeAudio = Uint8List.fromList(List.generate(1250, (i) => (i * 13) % 256));
      final chunks = BlePacketCodec.encodeVoiceChunks(
        messageId: testUuid,
        senderId: 'harshil',
        targetId: 'taksh',
        audioBlob: fakeAudio,
        durationMs: 3200,
        codecType: VoiceCodecType.amrNb,
        isGroup: false,
      );

      expect(chunks.length, equals(4)); // 360 + 360 + 360 + 170 = 1250
      final reassembled = BytesBuilder();

      for (int i = 0; i < chunks.length; i++) {
        expect(chunks[i].length, lessThanOrEqualTo(440));
        final pkt = BlePacketCodec.decode(chunks[i]);
        expect(pkt.isVoice, isTrue);
        expect(pkt.flags & BlePacketFlags.chunked, isNonZero);

        final chunk = BlePacketCodec.decodeVoiceChunk(pkt.payload);
        expect(chunk.chunkIndex, equals(i));
        expect(chunk.totalChunks, equals(4));
        expect(chunk.durationMs, equals(3200));
        expect(chunk.codecType, equals(VoiceCodecType.amrNb));
        reassembled.add(chunk.chunkBytes);
      }

      expect(reassembled.toBytes(), equals(fakeAudio));
    });

    test('PresenceHello, PeerDirectory, and GroupMeta roundtrip accurately', () {
      final helloBytes = BlePacketCodec.encodePresenceHello(
        deviceUuid: testUuid,
        username: 'harshil',
        displayName: 'Harshil',
      );
      final helloPkt = BlePacketCodec.decode(helloBytes);
      expect(helloPkt.isPresence, isTrue);
      expect(helloPkt.senderId, equals('harshil'));
      expect(helloPkt.targetId, equals('RELAY'));
      expect(helloPkt.textContent, equals('Harshil'));

      final groupBytes = BlePacketCodec.encodeGroupMeta(
        messageId: testUuid,
        senderId: 'harshil',
        groupId: 'g_123456',
        groupName: 'Mountain Rescue',
        members: ['harshil', 'Taksh', 'Priya'],
      );
      final groupPkt = BlePacketCodec.decode(groupBytes);
      expect(groupPkt.isGroupMeta, isTrue);
      expect(groupPkt.isGroup, isTrue);
      final decodedGroup = BlePacketCodec.decodeGroupMeta(groupPkt.targetId, groupPkt.payload);
      expect(decodedGroup.groupId, equals('g_123456'));
      expect(decodedGroup.groupName, equals('Mountain Rescue'));
      expect(decodedGroup.members, containsAll(['harshil', 'taksh', 'priya']));

      // Synthetic directory payload check
      final dirPayload = BytesBuilder()
        ..addByte(0)
        ..addByte(1)
        ..addByte(2)
        ..addByte(7)
        ..add('harshil'.codeUnits)
        ..addByte(7)
        ..add('Harshil'.codeUnits)
        ..addByte(1)
        ..addByte(5)
        ..add('taksh'.codeUnits)
        ..addByte(5)
        ..add('Taksh'.codeUnits)
        ..addByte(0);
      final dir = BlePacketCodec.decodePeerDirectory(dirPayload.toBytes());
      expect(dir.page, equals(0));
      expect(dir.totalPages, equals(1));
      expect(dir.peers.length, equals(2));
      expect(dir.peers[0].isOnline, isTrue);
      expect(dir.peers[1].username, equals('taksh'));
      expect(dir.peers[1].isOnline, isFalse);
    });

    test('CallSignal and CallAudio ADPCM packets encode & decode cleanly', () {
      final sigBytes = BlePacketCodec.encodeCallSignal(
        callId: callUuid,
        senderId: 'harshil',
        targetId: 'taksh',
        signalCode: CallSignalCode.invite,
      );
      final sigPkt = BlePacketCodec.decode(sigBytes);
      expect(sigPkt.isCallSignal, isTrue);
      expect(sigPkt.messageId, equals(callUuid));
      expect(sigPkt.payload[0], equals(CallSignalCode.invite));

      final nibbles = Uint8List.fromList(List.generate(160, (i) => i & 0xFF));
      final audioBytes = BlePacketCodec.encodeCallAudio(
        callId: callUuid,
        senderId: 'harshil',
        targetId: 'taksh',
        seqNum: 42,
        predictor: -1250,
        stepIndex: 18,
        frameMs: 40,
        adpcmBytes: nibbles,
      );
      final audioPkt = BlePacketCodec.decode(audioBytes);
      expect(audioPkt.isCallAudio, isTrue);
      expect(audioPkt.isCompressed, isTrue);

      final parsedFrame = BlePacketCodec.decodeCallAudio(audioPkt.payload);
      expect(parsedFrame.seqNum, equals(42));
      expect(parsedFrame.predictor, equals(-1250));
      expect(parsedFrame.stepIndex, equals(18));
      expect(parsedFrame.frameMs, equals(40));
      expect(parsedFrame.adpcmBytes, equals(nibbles));
    });

    test('Throws FormatException on short or wrong-version packets', () {
      expect(() => BlePacketCodec.decode(Uint8List(10)), throwsA(isA<FormatException>()));

      final wrongVer = BlePacketCodec.encodeText(
        messageId: testUuid,
        senderId: 'a',
        targetId: 'b',
        text: 'hello',
      );
      wrongVer[0] = 0x01;
      expect(() => BlePacketCodec.decode(wrongVer), throwsA(isA<FormatException>()));
    });
  });

  group('IMA-ADPCM Live Voice Compression & VAD Tests', () {
    test('Silence frame is suppressed by VAD while speech sine wave compresses 4:1', () {
      final encoder = ImaAdpcmCodec();

      // 320 samples (40ms @ 8kHz) = 640 bytes of silence
      final silencePcm = Uint8List(640);
      final silentFrame = encoder.encodePcm16(silencePcm);
      expect(silentFrame.isSilent, isTrue);

      // 320 samples (40ms @ 8kHz) of 500 Hz tone
      final speechPcm = Uint8List(640);
      final bd = ByteData.sublistView(speechPcm);
      for (int i = 0; i < 320; i++) {
        final v = (sin(2 * pi * 500 * (i / 8000.0)) * 14000).round();
        bd.setInt16(i * 2, v, Endian.little);
      }

      encoder.resetEncoder();
      final speechFrame = encoder.encodePcm16(speechPcm);
      expect(speechFrame.isSilent, isFalse);
      expect(speechFrame.nibbles.length, equals(160)); // Exact 4:1 compression (640 -> 160)

      final restoredPcm = ImaAdpcmCodec.decodeToPcm16(
        initialPredictor: speechFrame.initialPredictor,
        initialStepIndex: speechFrame.initialStepIndex,
        nibbles: speechFrame.nibbles,
      );
      expect(restoredPcm.length, equals(640));
    });
  });
}
