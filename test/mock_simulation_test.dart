import 'package:flutter_test/flutter_test.dart';
import 'package:message_mail/models/message_mail.dart';
import 'package:message_mail/providers/message_mail_provider.dart';
import 'package:message_mail/services/audio_service.dart';
import 'package:message_mail/services/ble_service.dart';
import 'package:message_mail/services/database_service.dart';
import 'package:message_mail/services/mock_ble_node_engine.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();

  group('Autonomous MockBleNodeEngine Simulation Tests', () {
    late Database rawDb;
    late DatabaseService dbService;
    late MockBleNodeEngine mockEngine;
    late AudioService audioService;
    late MessageMailProvider provider;

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
      mockEngine = MockBleNodeEngine();
      audioService = AudioService();

      provider = MessageMailProvider(
        db: dbService,
        audio: audioService,
        bridge: mockEngine,
      );
    });

    tearDown(() async {
      provider.dispose();
      await dbService.close();
    });

    test('Scenario 1: Phone out of range -> messages stay buffered in PENDING_LOCAL in SQLite', () async {
      // 1. Verify initially disconnected
      expect(provider.isConnected, isFalse);
      expect(provider.bleState, equals(BleConnectionState.disconnected));

      // 2. User attempts to send a text message while disconnected
      await provider.sendTextMessage('Survey team at ridge: No internet, using offline mail.');

      // 3. User records and sends a voice mail while disconnected
      final voiceBlob = AudioService.generateSyntheticVoiceMail(seconds: 3.0);
      await provider.sendVoiceMail(voiceBlob);

      // 4. Verify SQLite database holds both messages as PENDING_LOCAL
      final pendingList = await dbService.getPendingOutbox();
      expect(pendingList.length, equals(2));
      expect(pendingList[0].status, equals(MessageStatus.pendingLocal));
      expect(pendingList[0].payloadType, equals(PayloadType.text));
      expect(pendingList[1].status, equals(MessageStatus.pendingLocal));
      expect(pendingList[1].payloadType, equals(PayloadType.voiceMail));

      // 5. Verify nothing was transmitted across BLE yet
      expect(mockEngine.transmittedFrames, isEmpty);
      expect(provider.pendingSyncCount, equals(2));
    });

    test('Scenario 2: Phone connects to Node P1 -> auto-flush outbox to IN_TRANSIT over BLE', () async {
      // 1. Buffer 2 messages while offline
      await provider.sendTextMessage('Message 1: Water supply verified.');
      await provider.sendTextMessage('Message 2: Need relay confirmation.');

      expect(provider.pendingSyncCount, equals(2));
      expect(mockEngine.transmittedFrames.length, equals(0));

      // 2. Phone comes into Bluetooth range and connects to Node P1
      final connected = await provider.connectToNode('NODE-P1');
      expect(connected, isTrue);
      expect(provider.isConnected, isTrue);
      expect(provider.connectedNodeName, equals('NODE-P1'));

      // 3. Trigger flush (coordinator triggers automatically on connect event, or via explicit manualMeshSync)
      await provider.manualMeshSync();

      // 4. Verify mock engine received both framed packets over BLE
      expect(mockEngine.transmittedPackets.length, equals(2));

      final firstPacket = mockEngine.transmittedPackets[0];
      expect(firstPacket.isText, isTrue);
      expect(firstPacket.textContent, equals('Message 1: Water supply verified.'));

      final secondPacket = mockEngine.transmittedPackets[1];
      expect(secondPacket.isText, isTrue);
      expect(secondPacket.textContent, equals('Message 2: Need relay confirmation.'));

      // 5. Verify records in SQLite have transitioned from PENDING_LOCAL to IN_TRANSIT
      final pendingAfterSync = await dbService.getPendingOutbox();
      expect(pendingAfterSync, isEmpty);

      final allRecords = await dbService.getAllMessages();
      expect(allRecords.length, equals(2));
      expect(allRecords[0].status, equals(MessageStatus.inTransit));
      expect(allRecords[1].status, equals(MessageStatus.inTransit));

      final stats = await dbService.getDatabaseStats();
      expect(stats['PENDING_LOCAL'], equals(0));
      expect(stats['IN_TRANSIT'], equals(2));
    });

    test('Scenario 3: Node pushes incoming buffered message mail -> saves to SQLite and updates UI', () async {
      // Connect to node
      await provider.connectToNode('NODE-P1');
      provider.setActiveRecipient('NODE-P2');

      const incomingMsgId = '99999999-8888-7777-6666-555555555555';
      const incomingText = 'Heltec Node P1 relaying message from base camp!';

      // Simulate ESP32 node pushing RX packet from the LoRa mesh
      mockEngine.simulateIncomingText(
        messageId: incomingMsgId,
        senderNodeId: 'NODE-P2',
        text: incomingText,
      );

      // Allow async event loop to process
      await Future.delayed(const Duration(milliseconds: 60));

      // Verify message saved to SQLite as DELIVERED
      final savedMessage = await dbService.getMessageById(incomingMsgId);
      expect(savedMessage, isNotNull);
      expect(savedMessage!.textContent, equals(incomingText));
      expect(savedMessage.status, equals(MessageStatus.delivered));
      expect(savedMessage.senderId, equals('NODE-P2'));

      // Verify provider conversation messages refreshed
      expect(provider.conversationMessages.any((m) => m.id == incomingMsgId), isTrue);
    });

    test('Scenario 4: LoRa delivery ACK pushes from node -> updates IN_TRANSIT to DELIVERED', () async {
      await provider.connectToNode('NODE-P1');

      // Send message
      await provider.sendTextMessage('Packet awaiting mesh round-trip ACK');
      await provider.manualMeshSync();

      final inTransitRecords = await dbService.getAllMessages();
      expect(inTransitRecords.length, equals(1));
      final msgId = inTransitRecords.first.id;
      expect(inTransitRecords.first.status, equals(MessageStatus.inTransit));

      // Simulate remote recipient sending ACK across the LoRa mesh back to our local node
      mockEngine.simulateIncomingAck(
        messageId: msgId,
        recipientId: provider.localClientId,
        isDelivered: true,
      );

      await Future.delayed(const Duration(milliseconds: 60));

      // Verify status transitioned to DELIVERED in SQLite
      final ackedRecord = await dbService.getMessageById(msgId);
      expect(ackedRecord!.status, equals(MessageStatus.delivered));
    });
  });
}

