import 'dart:async';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'providers/message_mail_provider.dart';
import 'screens/call_screen.dart';
import 'screens/chat_screen.dart';
import 'screens/chats_home_screen.dart';
import 'screens/onboarding_screen.dart';
import 'services/audio_service.dart';
import 'services/database_service.dart';
import 'services/native_platform_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await [
      Permission.microphone,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.notification,
      Permission.location,
    ].request();
  } catch (_) {}

  final nativePlatform = NativePlatformService();
  final databaseService = DatabaseService();
  final audioService = AudioService(nativePlatform: nativePlatform);

  runApp(
    MessageMailApp(
      databaseService: databaseService,
      audioService: audioService,
      nativePlatform: nativePlatform,
    ),
  );
}

class MessageMailApp extends StatelessWidget {
  final DatabaseService databaseService;
  final AudioService audioService;
  final NativePlatformService nativePlatform;

  const MessageMailApp({
    super.key,
    required this.databaseService,
    required this.audioService,
    required this.nativePlatform,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<MessageMailProvider>(
      create: (_) => MessageMailProvider(
        db: databaseService,
        audio: audioService,
        nativePlatform: nativePlatform,
      ),
      child: MaterialApp(
        title: 'Off-Grid Message Mail',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0B141A),
          primaryColor: const Color(0xFF00A884),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF00A884),
            secondary: Color(0xFF25D366),
            surface: Color(0xFF1F2C34),
          ),
        ),
        builder: (context, child) {
          return Stack(
            children: [
              ?child,
              Consumer<MessageMailProvider>(
                builder: (context, provider, _) {
                  if (provider.callState.isActive) {
                    return const Positioned.fill(
                      child: CallScreen(),
                    );
                  }
                  return const SizedBox.shrink();
                },
              ),
            ],
          );
        },
        home: const _AppRootShell(),
      ),
    );
  }
}

class _AppRootShell extends StatefulWidget {
  const _AppRootShell();

  @override
  State<_AppRootShell> createState() => _AppRootShellState();
}

class _AppRootShellState extends State<_AppRootShell>
    with WidgetsBindingObserver {
  StreamSubscription? _navSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final provider = context.read<MessageMailProvider>();
      _navSub = provider.openChatNavigationStream.listen((target) {
        if (!mounted || !provider.isOnboarded) return;
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ChatScreen(
              chatId: target.chatId,
              isGroup: target.isGroup,
            ),
          ),
        );
      });
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    final provider = context.read<MessageMailProvider>();
    provider.setAppForeground(state == AppLifecycleState.resumed);
  }

  @override
  void dispose() {
    _navSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();

    if (!provider.isInitialized) {
      return const Scaffold(
        backgroundColor: Color(0xFF0B141A),
        body: Center(
          child: CircularProgressIndicator(color: Color(0xFF25D366)),
        ),
      );
    }

    final Widget baseScreen = provider.isOnboarded
        ? const ChatsHomeScreen()
        : const OnboardingScreen();

    return baseScreen;
  }
}
