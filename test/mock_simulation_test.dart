import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:message_mail/models/message_mail.dart';
import 'package:message_mail/protocol/ble_packet_codec.dart';
import 'package:message_mail/providers/message_mail_provider.dart';
import 'package:message_mail/services/audio_service.dart';
import 'package:message_mail/services/database_service.dart';
import 'package:message_mail/services/mock_ble_node_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('Protocol v2 End-to-End Mesh Provider Simulations', () {
    late Database rawDb;
    late DatabaseService dbService;
    late AudioService audioService;
    late MockBleNodeEngine mockBridge;
    late MessageMailProvider provider;

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
      audioService = AudioService();
      mockBridge = MockBleNodeEngine();
      provider = MessageMailProvider(
        db: dbService,
        audio: audioService,
        bridge: mockBridge,
        autoInit: false,
      );
      await provider.initialize();
    });

    tearDown(() async {
      provider.dispose();
      audioService.dispose();
      await dbService.close();
    });

    test('Unique username registration, relay conflict detection (Option A), and peer discovery', () async {
      expect(provider.isOnboarded, isFalse);

      await mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
      final registered = await provider.registerUsername('Harshil');
      expect(registered, isTrue);
      expect(provider.isOnboarded, isTrue);
      expect(provider.localUsername, equals('harshil'));

      await Future.delayed(const Duration(milliseconds: 30));
      expect(
        mockBridge.transmittedPackets.any(
          (p) => p.isPresence && p.senderId == 'harshil',
        ),
        isTrue,
      );

      // Relay flags duplicate name conflict -> provider prompts user
      mockBridge.simulatePresenceConflict('harshil');
      await Future.delayed(const Duration(milliseconds: 30));
      expect(provider.nameConflictMessage, isNotNull);
      expect(provider.nameConflictMessage, contains('harshil'));

      // Choosing another unique name clears conflict warning
      await provider.registerUsername('Harshil_2');
      await Future.delayed(const Duration(milliseconds: 30));
      expect(provider.nameConflictMessage, isNull);
      expect(provider.localUsername, equals('harshil_2'));

      // Peer directory sync discovers Taksh & Priya automatically
      mockBridge.simulatePeerDirectory(const [
        DirectoryPeerEntry(username: 'harshil_2', displayName: 'Harshil_2', isOnline: true),
        DirectoryPeerEntry(username: 'taksh', displayName: 'Taksh', isOnline: true),
        DirectoryPeerEntry(username: 'priya', displayName: 'Priya', isOnline: false),
      ]);
      await Future.delayed(const Duration(milliseconds: 30));

      expect(provider.peers.map((p) => p.username), containsAll(['taksh', 'priya']));
      expect(provider.peers.map((p) => p.username), isNot(contains('harshil_2')));
    });

    test('1-to-1 targeted text & chunked voice mail transfer directly by username', () async {
      await provider.registerUsername('Harshil');
      await mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
      mockBridge.simulatePeerDirectory(const [
        DirectoryPeerEntry(username: 'taksh', displayName: 'Taksh', isOnline: true),
      ]);
      await Future.delayed(const Duration(milliseconds: 20));
      mockBridge.clearTransmittedLogs();

      // Send 1-to-1 text to Taksh
      await provider.sendTextMessage('taksh', 'Hey Taksh, only you see this!');
      await Future.delayed(const Duration(milliseconds: 40));

      final sentText = mockBridge.transmittedPackets.where((p) => p.isText).toList();
      expect(sentText.length, equals(1));
      expect(sentText.first.senderId, equals('harshil'));
      expect(sentText.first.targetId, equals('taksh'));
      expect(sentText.first.isGroup, isFalse);

      // Simulate delivery ACK from Taksh
      mockBridge.simulateIncomingAck(
        messageId: sentText.first.messageId,
        senderId: 'taksh',
        targetId: 'harshil',
      );
      await Future.delayed(const Duration(milliseconds: 30));

      await provider.openChat('taksh');
      expect(provider.activeChatMessages.length, equals(1));
      expect(provider.activeChatMessages.first.status, equals(MessageStatus.delivered));
      provider.closeChat();

      // Receive incoming multi-chunk voice message from Taksh while chat is closed
      final wavBlob = AudioService.generateTestWavBlob(seconds: 0.25); // 4044 bytes -> multiple chunks
      mockBridge.simulateIncomingVoice(
        messageId: 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee',
        senderId: 'taksh',
        targetId: 'harshil',
        audioBlob: wavBlob,
        durationMs: 250,
        codecType: VoiceCodecType.wavPcm,
      );
      await Future.delayed(const Duration(milliseconds: 60));

      final takshSummary = provider.chatSummaries.firstWhere((c) => c.chatId == 'taksh');
      expect(takshSummary.unreadCount, equals(1));
      expect(takshSummary.lastMessage!.payloadType, equals(PayloadType.voiceMail));
      expect(takshSummary.lastMessage!.audioBlob, equals(wavBlob));
    });

    test('Group chat creation syncs metadata and tags group messages correctly', () async {
      await provider.registerUsername('Harshil');
      await mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
      mockBridge.clearTransmittedLogs();

      final group = await provider.createGroup(
        groupName: 'Base Camp',
        memberUsernames: ['taksh', 'priya'],
      );
      expect(group, isNotNull);
      await Future.delayed(const Duration(milliseconds: 30));

      expect(
        mockBridge.transmittedPackets.any(
          (p) => p.isGroupMeta && p.targetId == group!.groupId,
        ),
        isTrue,
      );

      await provider.sendTextMessage(group!.groupId, 'All team check in', isGroup: true);
      await Future.delayed(const Duration(milliseconds: 40));

      final sentGroupMsg = mockBridge.transmittedPackets.lastWhere((p) => p.isText);
      expect(sentGroupMsg.isGroup, isTrue);
      expect(sentGroupMsg.targetId, equals(group.groupId));
    });

    test('Live Voice Call state machine handles accept/hangup and unanswered voicemail prompt', () async {
      await provider.registerUsername('Harshil');
      await mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
      mockBridge.clearTransmittedLogs();

      // Outgoing call -> unavailable triggers unansweredPrompt
      await provider.startVoiceCall('taksh');
      expect(provider.callState.phase, equals(CallPhase.calling));

      final invitePkt = mockBridge.transmittedPackets.lastWhere((p) => p.isCallSignal);
      expect(invitePkt.payload[0], equals(CallSignalCode.invite));

      mockBridge.simulateCallSignal(
        callId: invitePkt.messageId,
        senderId: 'taksh',
        targetId: 'harshil',
        signalCode: CallSignalCode.unavailable,
      );
      await Future.delayed(const Duration(milliseconds: 30));
      expect(provider.callState.phase, equals(CallPhase.unansweredPrompt));

      // User chooses "Record Voicemail" and sends it
      provider.openVoicemailRecorderAfterMissedCall();
      expect(provider.callState.phase, equals(CallPhase.recordingVoicemail));

      final vmBlob = AudioService.generateTestWavBlob(seconds: 0.2);
      await provider.sendVoicemailFromMissedCall(
        RecordedVoiceNote(
          bytes: vmBlob,
          durationMs: 200,
          codecType: VoiceCodecType.wavPcm,
        ),
      );
      await Future.delayed(const Duration(milliseconds: 40));

      expect(provider.callState.phase, equals(CallPhase.idle));
      await provider.openChat('taksh');
      expect(
        provider.activeChatMessages.any((m) => m.payloadType == PayloadType.callLog),
        isTrue,
      );
      expect(
        provider.activeChatMessages.any((m) => m.payloadType == PayloadType.voiceMail),
        isTrue,
      );
    });

    test('Caller transitions to connected on ACCEPT and supports mute, speaker, and hangup', () async {
      await provider.registerUsername('Harshil');
      await mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
      mockBridge.clearTransmittedLogs();

      await provider.startVoiceCall('taksh');
      expect(provider.callState.phase, equals(CallPhase.calling));

      final invitePkt = mockBridge.transmittedPackets.lastWhere((p) => p.isCallSignal);
      mockBridge.simulateCallSignal(
        callId: invitePkt.messageId,
        senderId: 'taksh',
        targetId: 'harshil',
        signalCode: CallSignalCode.accept,
      );
      await Future.delayed(const Duration(milliseconds: 30));

      expect(provider.callState.phase, equals(CallPhase.connected));

      provider.toggleCallMute();
      expect(provider.callState.isMuted, isTrue);
      await provider.toggleCallSpeaker();
      expect(provider.callState.isSpeakerOn, isTrue);

      await provider.endActiveCall();
      await Future.delayed(const Duration(milliseconds: 30));
      expect(provider.callState.phase, equals(CallPhase.idle));
      expect(
        mockBridge.transmittedPackets.any(
          (p) => p.isCallSignal && p.payload.isNotEmpty && p.payload[0] == CallSignalCode.hangup,
        ),
        isTrue,
      );
    });

    test('Caller auto-promotes to connected and keeps mute/speaker state if audio arrives before ACCEPT', () async {
      await provider.registerUsername('Harshil');
      await mockBridge.connectToNode('OFFGRID-RELAY-DEVKIT');
      mockBridge.clearTransmittedLogs();

      await provider.startVoiceCall('taksh');
      expect(provider.callState.phase, equals(CallPhase.calling));

      // Caller toggles Mute and Speaker while ringing/calling before ACCEPT arrives
      provider.toggleCallMute();
      await provider.toggleCallSpeaker();
      expect(provider.callState.isMuted, isTrue);
      expect(provider.callState.isSpeakerOn, isTrue);

      final invitePkt = mockBridge.transmittedPackets.lastWhere((p) => p.isCallSignal);
      mockBridge.simulateIncomingCallAudio(
        callId: invitePkt.messageId,
        senderId: 'taksh',
        targetId: 'harshil',
        seqNum: 1,
      );
      await Future.delayed(const Duration(milliseconds: 30));

      expect(provider.callState.phase, equals(CallPhase.connected));
      expect(provider.callState.isMuted, isTrue);
      expect(provider.callState.isSpeakerOn, isTrue);

      await provider.endActiveCall();
    });
  });
}
