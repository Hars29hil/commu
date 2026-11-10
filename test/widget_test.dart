import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:message_mail/models/message_mail.dart';
import 'package:message_mail/providers/message_mail_provider.dart';
import 'package:message_mail/services/audio_service.dart';
import 'package:message_mail/services/database_service.dart';
import 'package:message_mail/services/mock_ble_node_engine.dart';
import 'package:message_mail/widgets/connection_status_pill.dart';
import 'package:message_mail/widgets/message_bubble.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  group('UI Component Widget Tests', () {
    testWidgets('MessageBubble renders outgoing text and local queue status badge', (WidgetTester tester) async {
      final mockEngine = MockBleNodeEngine();
      final audioService = AudioService();
      // Use null database so no SQLite isolate or locks are engaged in widget unit tests
      final provider = MessageMailProvider(
        db: DatabaseService(),
        audio: audioService,
        bridge: mockEngine,
      );

      const msg = MessageMail(
        id: 'bubble-test-1',
        senderId: 'CLIENT-A',
        recipientId: 'NODE-P2',
        payloadType: PayloadType.text,
        textContent: 'Field check complete. Proceeding to waypoint 4.',
        timestamp: 1690000000,
        status: MessageStatus.pendingLocal,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<MessageMailProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(
              body: MessageBubble(
                message: msg,
                isOutgoing: true,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Field check complete. Proceeding to waypoint 4.'), findsOneWidget);
      expect(find.text('⏳ Local Queue'), findsOneWidget);
      expect(find.text('TO: NODE-P2'), findsOneWidget);
    });

    testWidgets('MessageBubble renders incoming voice mail with Codec2 details', (WidgetTester tester) async {
      final mockEngine = MockBleNodeEngine();
      final audioService = AudioService();
      final provider = MessageMailProvider(
        db: DatabaseService(),
        audio: audioService,
        bridge: mockEngine,
      );

      final voiceBlob = AudioService.generateSyntheticVoiceMail(seconds: 3.0);
      final voiceMsg = MessageMail(
        id: 'voice-msg-1',
        senderId: 'NODE-P1',
        recipientId: 'CLIENT-A',
        payloadType: PayloadType.voiceMail,
        audioBlob: voiceBlob,
        timestamp: 1690000500,
        status: MessageStatus.delivered,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<MessageMailProvider>.value(
          value: provider,
          child: MaterialApp(
            home: Scaffold(
              body: MessageBubble(
                message: voiceMsg,
                isOutgoing: false,
              ),
            ),
          ),
        ),
      );

      expect(find.textContaining('Codec2 Voice Mail'), findsOneWidget);
      expect(find.text('✅ Delivered'), findsOneWidget);
      expect(find.text('FROM: NODE-P1'), findsOneWidget);
    });

    testWidgets('ConnectionStatusPill displays DISCONNECTED pill when offline', (WidgetTester tester) async {
      final mockEngine = MockBleNodeEngine();
      final audioService = AudioService();
      final provider = MessageMailProvider(
        db: DatabaseService(),
        audio: audioService,
        bridge: mockEngine,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider<MessageMailProvider>.value(
          value: provider,
          child: const MaterialApp(
            home: Scaffold(
              body: ConnectionStatusPill(),
            ),
          ),
        ),
      );

      expect(find.textContaining('DISCONNECTED (OFFLINE CACHE ACTIVE)'), findsOneWidget);
    });
  });
}
