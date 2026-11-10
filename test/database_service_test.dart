import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:message_mail/models/message_mail.dart';
import 'package:message_mail/services/database_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('DatabaseService Unit Tests', () {
    late Database rawDb;
    late DatabaseService dbService;

    setUp(() async {
      rawDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, version) async {
            await DatabaseService.createSchema(db);
          },
        ),
      );
      dbService = DatabaseService(rawDb);
    });

    tearDown(() async {
      await dbService.close();
    });

    test('saveOutgoingMessage stores record with PENDING_LOCAL status', () async {
      final msg = MessageMail(
        id: '11111111-2222-3333-4444-555555555555',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P2',
        payloadType: PayloadType.text,
        textContent: 'Tactical emergency alert',
        timestamp: 1690000000,
        status: MessageStatus.delivered, // Will be coerced to pendingLocal
      );

      await dbService.saveOutgoingMessage(msg);

      final retrieved = await dbService.getMessageById(msg.id);
      expect(retrieved, isNotNull);
      expect(retrieved!.id, equals(msg.id));
      expect(retrieved.status, equals(MessageStatus.pendingLocal));
      expect(retrieved.textContent, equals('Tactical emergency alert'));
    });

    test('getPendingOutbox retrieves records ordered chronologically by timestamp ASC', () async {
      final msg1 = MessageMail(
        id: 'msg-003',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P1',
        payloadType: PayloadType.text,
        textContent: 'Third created, later timestamp',
        timestamp: 3000,
        status: MessageStatus.pendingLocal,
      );

      final msg2 = MessageMail(
        id: 'msg-001',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P1',
        payloadType: PayloadType.text,
        textContent: 'First created, earliest timestamp',
        timestamp: 1000,
        status: MessageStatus.pendingLocal,
      );

      final msg3 = MessageMail(
        id: 'msg-002',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P1',
        payloadType: PayloadType.text,
        textContent: 'Second created, middle timestamp',
        timestamp: 2000,
        status: MessageStatus.pendingLocal,
      );

      await dbService.saveOutgoingMessage(msg1);
      await dbService.saveOutgoingMessage(msg2);
      await dbService.saveOutgoingMessage(msg3);

      final outbox = await dbService.getPendingOutbox();
      expect(outbox.length, equals(3));
      expect(outbox[0].id, equals('msg-001'));
      expect(outbox[1].id, equals('msg-002'));
      expect(outbox[2].id, equals('msg-003'));
    });

    test('markAsInTransit transitions status from PENDING_LOCAL to IN_TRANSIT', () async {
      final msg = MessageMail(
        id: 'msg-transit-test',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P3',
        payloadType: PayloadType.text,
        textContent: 'Testing transit update',
        timestamp: 1500,
        status: MessageStatus.pendingLocal,
      );

      await dbService.saveOutgoingMessage(msg);
      final affected = await dbService.markAsInTransit(msg.id);
      expect(affected, equals(1));

      final updated = await dbService.getMessageById(msg.id);
      expect(updated!.status, equals(MessageStatus.inTransit));

      // Should no longer appear in pending outbox
      final pending = await dbService.getPendingOutbox();
      expect(pending.where((m) => m.id == msg.id), isEmpty);
    });

    test('saveIncomingMessage stores record with DELIVERED status', () async {
      final msg = MessageMail(
        id: 'msg-incoming-01',
        senderId: 'NODE-P1',
        recipientId: 'CLIENT-A',
        payloadType: PayloadType.voiceMail,
        audioBlob: Uint8List.fromList([0x43, 0x32, 0x56, 0x4D, 0x01, 0x02]),
        timestamp: 2500,
        status: MessageStatus.pendingLocal, // Will be coerced to delivered
      );

      await dbService.saveIncomingMessage(msg);

      final retrieved = await dbService.getMessageById(msg.id);
      expect(retrieved, isNotNull);
      expect(retrieved!.status, equals(MessageStatus.delivered));
      expect(retrieved.payloadType, equals(PayloadType.voiceMail));
      expect(retrieved.audioBlob, equals(Uint8List.fromList([0x43, 0x32, 0x56, 0x4D, 0x01, 0x02])));
    });

    test('updateStatusByAck updates message status based on LoRa ACK', () async {
      final msg = MessageMail(
        id: 'msg-ack-test',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P5',
        payloadType: PayloadType.text,
        textContent: 'Relay packet waiting for ACK',
        timestamp: 5000,
        status: MessageStatus.pendingLocal,
      );

      await dbService.saveOutgoingMessage(msg);
      await dbService.markAsInTransit(msg.id);

      // ACK arrives confirming delivery
      await dbService.updateStatusByAck(msg.id, 'DELIVERED');
      var updated = await dbService.getMessageById(msg.id);
      expect(updated!.status, equals(MessageStatus.delivered));

      // Test failure ACK
      await dbService.updateStatusByAck(msg.id, 'FAILED');
      updated = await dbService.getMessageById(msg.id);
      expect(updated!.status, equals(MessageStatus.failed));
    });

    test('Schema enforces CHECK constraint on payload_type and status', () async {
      // Direct raw insert violating payload_type CHECK constraint
      expect(
        () async => await rawDb.execute('''
          INSERT INTO ${DatabaseService.tableName}
          (id, sender_id, recipient_id, payload_type, timestamp, status)
          VALUES ('bad-type', 'A', 'B', 'invalid_type', 100, 'PENDING_LOCAL')
        '''),
        throwsA(isA<DatabaseException>()),
      );

      // Direct raw insert violating status CHECK constraint
      expect(
        () async => await rawDb.execute('''
          INSERT INTO ${DatabaseService.tableName}
          (id, sender_id, recipient_id, payload_type, timestamp, status)
          VALUES ('bad-status', 'A', 'B', 'text', 100, 'UNKNOWN_STATUS')
        '''),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('Handles null and corrupt payload structures safely', () async {
      final textWithNullContent = MessageMail(
        id: 'null-text',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P1',
        payloadType: PayloadType.text,
        textContent: null,
        timestamp: 100,
        status: MessageStatus.pendingLocal,
      );

      await dbService.saveOutgoingMessage(textWithNullContent);
      final retrieved = await dbService.getMessageById('null-text');
      expect(retrieved, isNotNull);
      expect(retrieved!.textContent, isNull);
      expect(retrieved.audioBlob, isNull);

      final emptyAudio = MessageMail(
        id: 'empty-audio',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P1',
        payloadType: PayloadType.voiceMail,
        audioBlob: Uint8List(0),
        timestamp: 101,
        status: MessageStatus.pendingLocal,
      );

      await dbService.saveOutgoingMessage(emptyAudio);
      final retrievedAudio = await dbService.getMessageById('empty-audio');
      expect(retrievedAudio, isNotNull);
      expect(retrievedAudio!.audioBlob, isNotNull);
      expect(retrievedAudio.audioBlob!.length, equals(0));
    });

    test('getDatabaseStats correctly counts message buckets', () async {
      await dbService.saveOutgoingMessage(MessageMail(
        id: 'p1',
        senderId: 'A',
        recipientId: 'B',
        payloadType: PayloadType.text,
        timestamp: 1,
        status: MessageStatus.pendingLocal,
      ));
      await dbService.saveOutgoingMessage(MessageMail(
        id: 'p2',
        senderId: 'A',
        recipientId: 'B',
        payloadType: PayloadType.text,
        timestamp: 2,
        status: MessageStatus.pendingLocal,
      ));

      await dbService.markAsInTransit('p2');

      await dbService.saveIncomingMessage(MessageMail(
        id: 'd1',
        senderId: 'B',
        recipientId: 'A',
        payloadType: PayloadType.text,
        timestamp: 3,
        status: MessageStatus.delivered,
      ));

      final stats = await dbService.getDatabaseStats();
      expect(stats['PENDING_LOCAL'], equals(1));
      expect(stats['IN_TRANSIT'], equals(1));
      expect(stats['DELIVERED'], equals(1));
      expect(stats['FAILED'], equals(0));
      expect(stats['TOTAL'], equals(3));
    });

    test('resetStuckQueueToPending resets IN_TRANSIT and FAILED records to PENDING_LOCAL', () async {
      await dbService.saveOutgoingMessage(MessageMail(
        id: 'stuck-1',
        senderId: 'A',
        recipientId: 'B',
        payloadType: PayloadType.text,
        timestamp: 10,
        status: MessageStatus.pendingLocal,
      ));
      await dbService.markAsInTransit('stuck-1');

      await dbService.saveOutgoingMessage(MessageMail(
        id: 'stuck-2',
        senderId: 'A',
        recipientId: 'B',
        payloadType: PayloadType.text,
        timestamp: 11,
        status: MessageStatus.pendingLocal,
      ));
      await dbService.updateStatusByAck('stuck-2', 'FAILED');

      final resetCount = await dbService.resetStuckQueueToPending();
      expect(resetCount, equals(2));

      final pending = await dbService.getPendingOutbox();
      expect(pending.length, equals(2));
    });
  });
}

