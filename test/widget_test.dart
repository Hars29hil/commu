import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:message_mail/models/message_mail.dart';
import 'package:message_mail/protocol/ble_packet_codec.dart';
import 'package:message_mail/providers/message_mail_provider.dart';
import 'package:message_mail/screens/call_screen.dart';
import 'package:message_mail/screens/chats_home_screen.dart';
import 'package:message_mail/screens/onboarding_screen.dart';
import 'package:message_mail/services/audio_service.dart';
import 'package:message_mail/services/database_service.dart';
import 'package:message_mail/services/mock_ble_node_engine.dart';
import 'package:message_mail/widgets/connection_status_pill.dart';
import 'package:message_mail/widgets/message_bubble.dart';

Future<({
  DatabaseService dbService,
  AudioService audioService,
  MockBleNodeEngine mockBridge,
  MessageMailProvider provider,
})> _createTestHarness() async {
  final rawDb = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: DatabaseService.databaseVersion,
      singleInstance: false,
      onCreate: (db, version) async {
        await DatabaseService.createSchema(db);
      },
    ),
  );
  final dbService = DatabaseService(rawDb);
  final audioService = AudioService();
  final mockBridge = MockBleNodeEngine();
  final provider = MessageMailProvider(
    db: dbService,
    audio: audioService,
    bridge: mockBridge,
    autoInit: false,
  );
  await provider.initialize();
  return (
    dbService: dbService,
    audioService: audioService,
    mockBridge: mockBridge,
    provider: provider,
  );
}

Future<void> _disposeTestHarness(({
  DatabaseService dbService,
  AudioService audioService,
  MockBleNodeEngine mockBridge,
  MessageMailProvider provider,
}) h) async {
  h.provider.dispose();
  h.audioService.dispose();
  await h.dbService.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Off-Grid Message Mail v2 UI Widget Tests', () {
    testWidgets('OnboardingScreen registers unique username and updates provider', (tester) async {
      final h = (await tester.runAsync(_createTestHarness))!;
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<MessageMailProvider>.value(
            value: h.provider,
            child: const MaterialApp(home: OnboardingScreen()),
          ),
        );

        expect(find.text('Welcome to Off-Grid Mail'), findsOneWidget);
        await tester.enterText(find.byType(TextFormField), 'Harshil Patel');
        await tester.pump();
        expect(find.text('Mesh ID: @harshil_patel'), findsOneWidget);

        await tester.runAsync(() async {
          await h.provider.registerUsername('Harshil Patel');
        });
        await tester.pump();

        expect(h.provider.isOnboarded, isTrue);
        expect(h.provider.localUsername, equals('harshil_patel'));
      } finally {
        await tester.runAsync(() => _disposeTestHarness(h));
      }
    });

    testWidgets('ChatsHomeScreen renders search, peer discovery, and 1-to-1 / group summaries', (tester) async {
      final h = (await tester.runAsync(_createTestHarness))!;
      try {
        await tester.runAsync(() async {
          await h.provider.registerUsername('Harshil');
          h.mockBridge.simulatePeerDirectory(const [
            DirectoryPeerEntry(username: 'taksh', displayName: 'Taksh', isOnline: true),
            DirectoryPeerEntry(username: 'priya', displayName: 'Priya', isOnline: false),
          ]);
          await Future.delayed(const Duration(milliseconds: 50));
        });

        await tester.pumpWidget(
          ChangeNotifierProvider<MessageMailProvider>.value(
            value: h.provider,
            child: const MaterialApp(home: ChatsHomeScreen()),
          ),
        );
        await tester.pump();

        expect(find.text('Message Mail'), findsOneWidget);
        expect(find.text('Logged in as Harshil'), findsOneWidget);
        expect(find.text('Taksh'), findsOneWidget);
        expect(find.text('Priya'), findsOneWidget);

        // Search filters by username/display name
        await tester.enterText(find.byType(TextField), 'Taksh');
        await tester.pump();
        expect(
          find.descendant(of: find.byType(ListTile), matching: find.text('Taksh')),
          findsOneWidget,
        );
        expect(find.text('Priya'), findsNothing);
      } finally {
        await tester.runAsync(() => _disposeTestHarness(h));
      }
    });

    testWidgets('MessageBubble renders text, group attribution, compressed voice note, and call log', (tester) async {
      final h = (await tester.runAsync(_createTestHarness))!;
      try {
        await tester.runAsync(() async {
          await h.provider.registerUsername('Harshil');
          h.mockBridge.simulatePeerDirectory(const [
            DirectoryPeerEntry(username: 'taksh', displayName: 'Taksh', isOnline: true),
          ]);
          await Future.delayed(const Duration(milliseconds: 50));
        });

        final textMsg = MessageMail(
          id: 't1',
          chatId: 'g_1',
          senderId: 'taksh',
          recipientId: 'g_1',
          isGroup: true,
          payloadType: PayloadType.text,
          textContent: 'Reached north gate!',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: MessageStatus.delivered,
        );

        final voiceMsg = MessageMail(
          id: 'v1',
          chatId: 'taksh',
          senderId: 'harshil',
          recipientId: 'taksh',
          payloadType: PayloadType.voiceMail,
          audioBlob: AudioService.generateTestWavBlob(seconds: 0.5),
          durationMs: 2000,
          codecType: VoiceCodecType.amrNb,
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: MessageStatus.delivered,
        );

        final callLogMsg = MessageMail(
          id: 'c1',
          chatId: 'taksh',
          senderId: 'harshil',
          recipientId: 'taksh',
          payloadType: PayloadType.callLog,
          textContent: 'Unanswered call',
          timestamp: DateTime.now().millisecondsSinceEpoch,
          status: MessageStatus.delivered,
        );

        await tester.pumpWidget(
          ChangeNotifierProvider<MessageMailProvider>.value(
            value: h.provider,
            child: MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Column(
                    children: [
                      MessageBubble(message: textMsg, isOutgoing: false),
                      MessageBubble(message: voiceMsg, isOutgoing: true),
                      MessageBubble(message: callLogMsg, isOutgoing: true),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        expect(find.text('Taksh'), findsOneWidget);
        expect(find.text('Reached north gate!'), findsOneWidget);
        expect(find.byIcon(Icons.play_arrow), findsOneWidget);
        expect(find.text('0:02'), findsOneWidget);
        expect(find.byIcon(Icons.done_all), findsOneWidget);
        expect(find.textContaining('Unanswered call'), findsOneWidget);
      } finally {
        await tester.runAsync(() => _disposeTestHarness(h));
      }
    });

    testWidgets('ConnectionStatusPill reflects live BLE connection and offline cache states', (tester) async {
      final h = (await tester.runAsync(_createTestHarness))!;
      try {
        await tester.pumpWidget(
          ChangeNotifierProvider<MessageMailProvider>.value(
            value: h.provider,
            child: const MaterialApp(
              home: Scaffold(body: ConnectionStatusPill()),
            ),
          ),
        );

        expect(find.text('OFFLINE (OFFLINE CACHE ACTIVE)'), findsOneWidget);

        await tester.runAsync(() async {
          await h.mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
          await Future.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();

        expect(find.textContaining('ONLINE • OFFGRID-RELAY-DEVKIT'), findsOneWidget);
      } finally {
        await tester.runAsync(() => _disposeTestHarness(h));
      }
    });

    testWidgets('CallScreen exposes Mute, Speaker, and End Call controls for caller before and after accept', (tester) async {
      final h = (await tester.runAsync(_createTestHarness))!;
      try {
        await tester.runAsync(() async {
          await h.provider.registerUsername('Harshil');
          await h.mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
          await h.provider.startVoiceCall('taksh');
        });

        await tester.pumpWidget(
          ChangeNotifierProvider<MessageMailProvider>.value(
            value: h.provider,
            child: const MaterialApp(home: CallScreen()),
          ),
        );
        await tester.pump();

        expect(h.provider.callState.phase, equals(CallPhase.calling));
        expect(find.text('Mute'), findsOneWidget);
        expect(find.text('Speaker'), findsOneWidget);
        expect(find.text('End Call'), findsOneWidget);

        await tester.tap(find.text('Mute'));
        await tester.pump();
        expect(find.text('Unmute'), findsOneWidget);
        expect(h.provider.callState.isMuted, isTrue);

        await tester.tap(find.text('Speaker'));
        await tester.pump();
        expect(h.provider.callState.isSpeakerOn, isTrue);

        await tester.runAsync(() async {
          final invitePkt = h.mockBridge.transmittedPackets.lastWhere((p) => p.isCallSignal);
          h.mockBridge.simulateCallSignal(
            callId: invitePkt.messageId,
            senderId: 'taksh',
            targetId: 'harshil',
            signalCode: CallSignalCode.accept,
          );
          await Future.delayed(const Duration(milliseconds: 30));
        });
        await tester.pump();

        expect(h.provider.callState.phase, equals(CallPhase.connected));
        expect(find.text('Unmute'), findsOneWidget);
        expect(find.text('Speaker'), findsOneWidget);
        expect(find.text('End Call'), findsOneWidget);

        await tester.runAsync(() => h.provider.endActiveCall());
      } finally {
        await tester.runAsync(() => _disposeTestHarness(h));
      }
    });
  });
}
