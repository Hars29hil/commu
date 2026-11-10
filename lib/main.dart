import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'providers/message_mail_provider.dart';
import 'screens/home_screen.dart';
import 'services/audio_service.dart';
import 'services/database_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Request runtime permissions gracefully on Android/iOS
  try {
    await [
      Permission.microphone,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  } catch (_) {
    // Graceful fallback for non-mobile platforms (desktop / testing)
  }

  final databaseService = DatabaseService();
  final audioService = AudioService();

  runApp(
    MessageMailApp(
      databaseService: databaseService,
      audioService: audioService,
    ),
  );
}

class MessageMailApp extends StatelessWidget {
  final DatabaseService databaseService;
  final AudioService audioService;

  const MessageMailApp({
    super.key,
    required this.databaseService,
    required this.audioService,
  });

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<MessageMailProvider>(
      create: (_) => MessageMailProvider(
        db: databaseService,
        audio: audioService,
      ),
      child: MaterialApp(
        title: 'Off-Grid Message Mail',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.dark,
          scaffoldBackgroundColor: const Color(0xFF0F1117),
          primaryColor: const Color(0xFF3B82F6),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF3B82F6),
            secondary: Color(0xFF00E676),
            surface: Color(0xFF161922),
          ),
          fontFamily: 'Roboto',
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
