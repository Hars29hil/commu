import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:message_mail/protocol/ble_packet_codec.dart';

void main() {
  group('BlePacketCodec Protocol Framing Tests', () {
    const testUuid = 'c73bcdcc-66b7-4d2b-9dd7-25e1a7b4582e';
    const testRecipient = 'NODE-P01';

    test('Round-trip serialization of UTF-8 Text Packet', () {
      const textMessage = 'Mesh coordinates: 37.7749 N, 122.4194 W. Battery 94%.';

      final encoded = BlePacketCodec.encodeText(
        messageId: testUuid,
        recipientId: testRecipient,
        text: textMessage,
      );

      // Verify framing dimensions:
      // Header = 27 bytes: 16 (UUID) + 1 (Type) + 8 (Recipient) + 2 (Length)
      final expectedPayloadLen = utf8.encode(textMessage).length;
      expect(encoded.length, equals(BlePacketCodec.headerLength + expectedPayloadLen));

      // Verify Payload Type Flag (0x01 = UTF-8 Text)
      expect(encoded[16], equals(BlePayloadFlag.utf8Text));

      // Verify Length bytes Big Endian
      final byteData = ByteData.sublistView(encoded);
      expect(byteData.getUint16(25, Endian.big), equals(expectedPayloadLen));

      // Decode and verify round-trip integrity
      final decoded = BlePacketCodec.decode(encoded);
      expect(decoded.messageId.toLowerCase(), equals(testUuid.toLowerCase()));
      expect(decoded.payloadTypeFlag, equals(BlePayloadFlag.utf8Text));
      expect(decoded.recipientId, equals(testRecipient));
      expect(decoded.textContent, equals(textMessage));
      expect(decoded.isText, isTrue);
      expect(decoded.isVoice, isFalse);
    });

    test('Round-trip serialization of Compressed Binary Voice Chunk', () {
      // 720-byte synthetic Codec2 compressed frame buffer
      final rawVoiceBlob = Uint8List(720);
      for (int i = 0; i < rawVoiceBlob.length; i++) {
        rawVoiceBlob[i] = (i * 7 + 13) % 256;
      }

      final encoded = BlePacketCodec.encodeVoice(
        messageId: testUuid,
        recipientId: 'NODE-P2',
        audioBlob: rawVoiceBlob,
      );

      expect(encoded.length, equals(BlePacketCodec.headerLength + 720));
      expect(encoded[16], equals(BlePayloadFlag.voiceChunk));

      final decoded = BlePacketCodec.decode(encoded);
      expect(decoded.messageId.toLowerCase(), equals(testUuid.toLowerCase()));
      expect(decoded.payloadTypeFlag, equals(BlePayloadFlag.voiceChunk));
      expect(decoded.recipientId, equals('NODE-P2'));
      expect(decoded.payload, equals(rawVoiceBlob));
      expect(decoded.isVoice, isTrue);
      expect(decoded.isText, isFalse);
    });

    test('Round-trip serialization of Delivery ACK Packet', () {
      final encoded = BlePacketCodec.encodeAck(
        messageId: testUuid,
        recipientId: 'NODE-P3',
        statusCode: 0x01, // DELIVERED
      );

      expect(encoded.length, equals(BlePacketCodec.headerLength + 1));
      expect(encoded[16], equals(BlePayloadFlag.deliveryAck));
      expect(encoded[27], equals(0x01));

      final decoded = BlePacketCodec.decode(encoded);
      expect(decoded.messageId.toLowerCase(), equals(testUuid.toLowerCase()));
      expect(decoded.payloadTypeFlag, equals(BlePayloadFlag.deliveryAck));
      expect(decoded.recipientId, equals('NODE-P3'));
      expect(decoded.payload[0], equals(0x01));
      expect(decoded.isAck, isTrue);
    });

    test('UUID 16-byte conversion maintains exact bit layout', () {
      final packet = BlePacket(
        messageId: '00112233-4455-6677-8899-aabbccddeeff',
        payloadTypeFlag: BlePayloadFlag.utf8Text,
        recipientId: 'N1',
        payload: Uint8List(0),
      );

      final encoded = BlePacketCodec.encode(packet);
      final uuidSlice = encoded.sublist(0, 16);

      expect(uuidSlice, equals(Uint8List.fromList([
        0x00, 0x11, 0x22, 0x33,
        0x44, 0x55, 0x66, 0x77,
        0x88, 0x99, 0xAA, 0xBB,
        0xCC, 0xDD, 0xEE, 0xFF,
      ])));

      final decoded = BlePacketCodec.decode(encoded);
      expect(decoded.messageId, equals('00112233-4455-6677-8899-aabbccddeeff'));
    });

    test('Recipient field handles 8-byte padding and trimming cleanly', () {
      final shortRecipient = 'P1';
      final encodedShort = BlePacketCodec.encodeText(
        messageId: testUuid,
        recipientId: shortRecipient,
        text: 'hello',
      );
      final decodedShort = BlePacketCodec.decode(encodedShort);
      expect(decodedShort.recipientId, equals('P1'));

      final exactRecipient = 'NODE-P06'; // exactly 8 chars
      final encodedExact = BlePacketCodec.encodeText(
        messageId: testUuid,
        recipientId: exactRecipient,
        text: 'hello',
      );
      final decodedExact = BlePacketCodec.decode(encodedExact);
      expect(decodedExact.recipientId, equals('NODE-P06'));
    });

    test('Throws FormatException on truncated packets', () {
      // Shorter than 27-byte header
      final tooShort = Uint8List(20);
      expect(() => BlePacketCodec.decode(tooShort), throwsA(isA<FormatException>()));

      // Header indicates 50-byte payload, but only 10 bytes provided
      final headerWithLongPayload = Uint8List(37);
      ByteData.sublistView(headerWithLongPayload).setUint16(25, 50, Endian.big);
      expect(() => BlePacketCodec.decode(headerWithLongPayload), throwsA(isA<FormatException>()));
    });
  });
}

