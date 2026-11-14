import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message_mail.dart';
import '../providers/message_mail_provider.dart';

/// Diagnostic & Relay Inspector Drawer (accessible from the home menu).
class OutboxDiagnosticDrawer extends StatelessWidget {
  const OutboxDiagnosticDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final stats = provider.dbStats;
    final allMessages = provider.allMessages;

    return Drawer(
      backgroundColor: const Color(0xFF111B21),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF1F2C34),
                border: Border(bottom: BorderSide(color: Colors.white12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.analytics_outlined,
                          color: Color(0xFF25D366), size: 20),
                      SizedBox(width: 8),
                      Text(
                        'RELAY DIAGNOSTICS',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.7,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _statTile('PENDING', stats['PENDING_LOCAL'] ?? 0,
                          const Color(0xFFFFB300)),
                      _statTile('IN TRANSIT', stats['IN_TRANSIT'] ?? 0,
                          const Color(0xFF38BDF8)),
                      _statTile('DELIVERED', stats['DELIVERED'] ?? 0,
                          const Color(0xFF4ADE80)),
                      _statTile('FAILED', stats['FAILED'] ?? 0,
                          const Color(0xFFF87171)),
                    ],
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              color: const Color(0xFF162027),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        provider.isUsingMock
                            ? 'MODE: MOCK SIMULATOR'
                            : 'MODE: PHYSICAL BLE',
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                          fontFamily: 'monospace',
                        ),
                      ),
                      Switch(
                        value: provider.isUsingMock,
                        activeThumbColor: const Color(0xFF25D366),
                        onChanged: (val) => provider.toggleHardwareBridge(val),
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.sync, size: 14),
                          label: const Text('SYNC NOW',
                              style: TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF00A884),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: provider.isConnected
                              ? () => provider.manualMeshSync()
                              : null,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.refresh, size: 14),
                          label: const Text('RETRY STUCK',
                              style: TextStyle(fontSize: 11)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFFFB300),
                            side: const BorderSide(color: Color(0xFFFFB300)),
                          ),
                          onPressed: () => provider.resetStuckQueue(),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white12),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'LOCAL QUEUE LOG',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(
                    '${allMessages.length} records',
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: allMessages.isEmpty
                  ? const Center(
                      child: Text(
                        'No messages stored yet.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      itemCount: allMessages.length,
                      itemBuilder: (context, idx) {
                        final msg = allMessages[allMessages.length - 1 - idx];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            msg.payloadType == PayloadType.voiceMail
                                ? Icons.mic
                                : msg.payloadType == PayloadType.callLog
                                    ? Icons.call
                                    : Icons.chat_bubble_outline,
                            color: Colors.white54,
                            size: 16,
                          ),
                          title: Text(
                            '${msg.senderId} → ${msg.recipientId}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: Text(
                            msg.payloadType == PayloadType.voiceMail
                                ? 'Voice (${msg.audioBlob?.length ?? 0} B)'
                                : (msg.textContent ?? ''),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(color: Colors.white54, fontSize: 11),
                          ),
                          trailing: Text(
                            msg.status.value,
                            style: const TextStyle(
                              color: Color(0xFF38BDF8),
                              fontSize: 9.5,
                              fontFamily: 'monospace',
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: TextButton.icon(
                icon: const Icon(Icons.delete_sweep,
                    color: Colors.white38, size: 16),
                label: const Text(
                  'Clear Message History',
                  style: TextStyle(color: Colors.white38, fontSize: 11),
                ),
                onPressed: () => provider.clearAllDatabase(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statTile(String label, int count, Color color) {
    return Column(
      children: [
        Text(
          '$count',
          style: TextStyle(
            color: color,
            fontSize: 16,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
