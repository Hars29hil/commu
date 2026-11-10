import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';
import '../widgets/connection_status_pill.dart';
import '../widgets/message_bubble.dart';
import '../widgets/outbox_diagnostic_drawer.dart';
import '../widgets/voice_recorder_bar.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final conversationMessages = provider.conversationMessages;

    return Scaffold(
      backgroundColor: const Color(0xFF0F1117), // Deep off-grid dark theme
      appBar: AppBar(
        backgroundColor: const Color(0xFF161922),
        elevation: 0,
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                color: const Color(0xFF3B82F6).withValues(alpha: 0.2),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.cell_tower,
                color: Color(0xFF60A5FA),
                size: 18,
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'MESSAGE MAIL',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.1,
                    fontFamily: 'monospace',
                  ),
                ),
                Text(
                  '5 KM DECENTRALIZED LORA MESH',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 8.5,
                    letterSpacing: 0.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
          ],
        ),
        actions: [
          // Dual Node Identity & Recipient Selector
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: const Color(0xFF232936),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white12),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Local Client ID (ME)
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: provider.localClientId,
                    dropdownColor: const Color(0xFF1E222D),
                    icon: const Icon(Icons.arrow_drop_down,
                        color: Color(0xFF38BDF8), size: 16),
                    style: const TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'NODE-P1', child: Text('ME: P1')),
                      DropdownMenuItem(value: 'NODE-P2', child: Text('ME: P2')),
                      DropdownMenuItem(value: 'NODE-P3', child: Text('ME: P3')),
                      DropdownMenuItem(value: 'NODE-P4', child: Text('ME: P4')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        provider.setLocalClientId(val);
                      }
                    },
                  ),
                ),
                const Icon(Icons.arrow_forward, size: 12, color: Colors.white38),
                const SizedBox(width: 2),
                // Recipient ID (TO)
                DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: provider.activeRecipientId,
                    dropdownColor: const Color(0xFF1E222D),
                    icon: const Icon(Icons.arrow_drop_down,
                        color: Color(0xFF00E676), size: 16),
                    style: const TextStyle(
                      color: Color(0xFF00E676),
                      fontSize: 10.5,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                    items: const [
                      DropdownMenuItem(value: 'NODE-P1', child: Text('TO: P1')),
                      DropdownMenuItem(value: 'NODE-P2', child: Text('TO: P2')),
                      DropdownMenuItem(value: 'NODE-P3', child: Text('TO: P3')),
                      DropdownMenuItem(value: 'NODE-P4', child: Text('TO: P4')),
                      DropdownMenuItem(value: 'ALL', child: Text('TO: ALL')),
                    ],
                    onChanged: (val) {
                      if (val != null) {
                        provider.setActiveRecipient(val);
                      }
                    },
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),

          // Diagnostic Drawer Button with Badge
          Builder(
            builder: (ctx) {
              return Stack(
                alignment: Alignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.tune, color: Colors.white70),
                    tooltip: 'Outbox Diagnostic Drawer',
                    onPressed: () {
                      Scaffold.of(ctx).openEndDrawer();
                    },
                  ),
                  if (provider.pendingSyncCount > 0)
                    Positioned(
                      top: 10,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Color(0xFFFF9100),
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          '${provider.pendingSyncCount}',
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 9,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      endDrawer: const OutboxDiagnosticDrawer(),
      body: Column(
        children: [
          // Hardware Connection Pill
          const ConnectionStatusPill(),

          // Conversation Stream
          Expanded(
            child: conversationMessages.isEmpty
                ? _buildEmptyConversationView(provider)
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: conversationMessages.length,
                    itemBuilder: (context, index) {
                      final message = conversationMessages[index];
                      final isOutgoing =
                          message.senderId == provider.localClientId;
                      return MessageBubble(
                        message: message,
                        isOutgoing: isOutgoing,
                      );
                    },
                  ),
          ),

          // Voice Mail Hold-To-Record & Text Input Bar
          const VoiceRecorderBar(),
        ],
      ),
    );
  }

  Widget _buildEmptyConversationView(MessageMailProvider provider) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: const Color(0xFF1E222D),
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white12),
              ),
              child: const Icon(
                Icons.satellite_alt_outlined,
                color: Color(0xFF60A5FA),
                size: 40,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'No messages exchanged with ${provider.activeRecipientId}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Compose an offline message mail or hold the microphone button to record a compact Codec2 voice mail. Messages buffer locally in SQLite and auto-flush over BLE whenever a LoRa node is within range.',
              style: TextStyle(
                color: Colors.white54,
                fontSize: 12,
                height: 1.4,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

