import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:message_mail/models/message_mail.dart';
import 'package:message_mail/protocol/ble_packet_codec.dart';
import 'package:message_mail/services/database_service.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SQLite Schema v2 DatabaseService Tests', () {
    late Database rawDb;
    late DatabaseService dbService;

    setUp(() async {
      rawDb = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: DatabaseService.databaseVersion,
          singleInstance: false,
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

    test('Stores and retrieves LocalProfile, Peers, and Groups', () async {
      const profile = LocalProfile(
        deviceUuid: '11111111-1111-1111-1111-111111111111',
        username: 'harshil',
        displayName: 'Harshil',
        isVerifiedOnRelay: true,
      );
      await dbService.saveLocalProfile(profile);
      final loaded = await dbService.getLocalProfile();
      expect(loaded, isNotNull);
      expect(loaded!.username, equals('harshil'));
      expect(loaded.isVerifiedOnRelay, isTrue);

      await dbService.upsertPeers(const [
        DirectoryPeerEntry(username: 'harshil', displayName: 'Harshil', isOnline: true),
        DirectoryPeerEntry(username: 'taksh', displayName: 'Taksh', isOnline: true),
        DirectoryPeerEntry(username: 'priya', displayName: 'Priya', isOnline: false),
      ]);

      final otherPeers = await dbService.getPeers(excludeUsername: 'harshil');
      expect(otherPeers.length, equals(2));
      expect(otherPeers.first.username, equals('taksh')); // online sorted first

      await dbService.setAllPeersOffline();
      final takshAfter = await dbService.getPeer('taksh');
      expect(takshAfter!.isOnline, isFalse);

      final group = ChatGroup(
        groupId: 'g_trek1',
        groupName: 'Trek Squad',
        createdBy: 'harshil',
        createdAt: 1000,
        members: const ['harshil', 'taksh', 'priya'],
      );
      await dbService.saveGroup(group);
      final fetchedGroup = await dbService.getGroupById('g_trek1');
      expect(fetchedGroup, isNotNull);
      expect(fetchedGroup!.groupName, equals('Trek Squad'));
      expect(fetchedGroup.members, containsAll(['harshil', 'taksh', 'priya']));
    });

    test('Stores 1-to-1 and Group messages, tracks unread counts & ChatSummaries', () async {
      await dbService.upsertPeers(const [
        DirectoryPeerEntry(username: 'taksh', displayName: 'Taksh', isOnline: true),
      ]);
      await dbService.saveGroup(
        const ChatGroup(
          groupId: 'g_ops',
          groupName: 'Rescue Ops',
          createdBy: 'harshil',
          createdAt: 900,
          members: ['harshil', 'taksh'],
        ),
      );

      final m1 = MessageMail(
        id: 'm1',
        chatId: 'taksh',
        senderId: 'taksh',
        recipientId: 'harshil',
        payloadType: PayloadType.text,
        textContent: 'Reached north gate',
        isRead: false,
        timestamp: 2000,
        status: MessageStatus.delivered,
      );
      await dbService.saveIncomingMessage(m1);

      final m2 = MessageMail(
        id: 'm2',
        chatId: 'g_ops',
        senderId: 'harshil',
        recipientId: 'g_ops',
        isGroup: true,
        payloadType: PayloadType.voiceMail,
        audioBlob: Uint8List.fromList([1, 2, 3, 4]),
        durationMs: 2400,
        codecType: VoiceCodecType.amrNb,
        timestamp: 3000,
        status: MessageStatus.pendingLocal,
      );
      await dbService.saveOutgoingMessage(m2);

      var summaries = await dbService.getChatSummaries('harshil');
      expect(summaries.length, equals(2));
      // Most recent activity first
      expect(summaries[0].chatId, equals('g_ops'));
      expect(summaries[0].isGroup, isTrue);
      expect(summaries[1].chatId, equals('taksh'));
      expect(summaries[1].unreadCount, equals(1));

      await dbService.markChatAsRead('taksh');
      summaries = await dbService.getChatSummaries('harshil');
      final takshSummary = summaries.firstWhere((c) => c.chatId == 'taksh');
      expect(takshSummary.unreadCount, equals(0));
    });

    test('Outbox queue lifecycle: pending -> inTransit -> delivered / failed & reset', () async {
      final msg = MessageMail(
        id: 'out-1',
        chatId: 'taksh',
        senderId: 'harshil',
        recipientId: 'taksh',
        payloadType: PayloadType.text,
        textContent: 'Queued offline',
        timestamp: 100,
        status: MessageStatus.pendingLocal,
      );
      await dbService.saveOutgoingMessage(msg);
      expect((await dbService.getPendingOutbox()).length, equals(1));

      await dbService.markAsInTransit('out-1');
      expect((await dbService.getPendingOutbox()), isEmpty);

      await dbService.updateStatusByAck('out-1', 'DELIVERED');
      expect((await dbService.getMessageById('out-1'))!.status, equals(MessageStatus.delivered));

      await dbService.updateStatusByAck('out-1', 'FAILED');
      expect((await dbService.getMessageById('out-1'))!.status, equals(MessageStatus.failed));

      final reset = await dbService.resetStuckQueueToPending();
      expect(reset, equals(1));
      expect((await dbService.getPendingOutbox()).length, equals(1));
    });

    test('Call logs do not enter BLE pending outbox and pass SQLite CHECK constraint', () async {
      final callLog = MessageMail(
        id: 'call-1',
        chatId: 'taksh',
        senderId: 'harshil',
        recipientId: 'taksh',
        payloadType: PayloadType.callLog,
        textContent: 'Voice call (0:15)',
        timestamp: 500,
        status: MessageStatus.delivered,
      );
      await dbService.saveOutgoingMessage(callLog);

      final outbox = await dbService.getPendingOutbox();
      expect(outbox, isEmpty);

      final chatMsgs = await dbService.getMessagesForChat('taksh');
      expect(chatMsgs.length, equals(1));
      expect(chatMsgs.first.payloadType, equals(PayloadType.callLog));

      expect(
        () async => rawDb.execute('''
          INSERT INTO ${DatabaseService.tableName}
          (id, chat_id, sender_id, recipient_id, payload_type, timestamp, status)
          VALUES ('bad', 'taksh', 'a', 'b', 'bogus_type', 1, 'PENDING_LOCAL')
        '''),
        throwsA(isA<DatabaseException>()),
      );
    });

    test('getDatabaseStats reports accurate message counts', () async {
      await dbService.saveOutgoingMessage(MessageMail(
        id: 'p1',
        chatId: 'taksh',
        senderId: 'harshil',
        recipientId: 'taksh',
        payloadType: PayloadType.text,
        timestamp: 1,
        status: MessageStatus.pendingLocal,
      ));
      await dbService.saveOutgoingMessage(MessageMail(
        id: 'p2',
        chatId: 'taksh',
        senderId: 'harshil',
        recipientId: 'taksh',
        payloadType: PayloadType.text,
        timestamp: 2,
        status: MessageStatus.pendingLocal,
      ));
      await dbService.markAsInTransit('p2');
      await dbService.saveIncomingMessage(MessageMail(
        id: 'd1',
        chatId: 'taksh',
        senderId: 'taksh',
        recipientId: 'harshil',
        payloadType: PayloadType.text,
        timestamp: 3,
        status: MessageStatus.delivered,
      ));

      final stats = await dbService.getDatabaseStats();
      expect(stats['PENDING_LOCAL'], equals(1));
      expect(stats['IN_TRANSIT'], equals(1));
      expect(stats['DELIVERED'], equals(1));
      expect(stats['TOTAL'], equals(3));
    });
  });
}
