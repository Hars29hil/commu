import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message_mail.dart';
import '../providers/message_mail_provider.dart';

/// Diagnostic Outbox Drawer matching technical requirements:
/// - Inspect SQLite records
/// - Inspect hex payload sizes
/// - Trigger manual mesh sync
/// - Clear stuck queues
/// - Direct simulation controls for 5 km Mesh Node links
class OutboxDiagnosticDrawer extends StatelessWidget {
  const OutboxDiagnosticDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final stats = provider.dbStats;
    final allMessages = provider.allMessages;

    return Drawer(
      backgroundColor: const Color(0xFF13161F),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Drawer Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1F2C),
                border: Border(bottom: BorderSide(color: Colors.white12)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.analytics_outlined,
                          color: Color(0xFF38BDF8), size: 20),
                      const SizedBox(width: 8),
                      const Text(
                        'DIAGNOSTIC OUTBOX DRAWER',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.8,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  // Stats Grid
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

            // Hardware & Simulation Toolbar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              color: const Color(0xFF161922),
              child: Column(
                children: [
                  // Hardware Mode Switch
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
                        activeThumbColor: const Color(0xFF38BDF8),
                        onChanged: (val) {
                          provider.toggleHardwareBridge(val);
                        },
                      ),
                    ],
                  ),

                  // Actions Row: Manual Mesh Sync & Reset Stuck Queue
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.sync, size: 14),
                          label: const Text('SYNC MESH',
                              style: TextStyle(fontSize: 11)),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 8),
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
                          label: const Text('CLEAR STUCK',
                              style: TextStyle(fontSize: 11)),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: const Color(0xFFFFB300),
                            side: const BorderSide(color: Color(0xFFFFB300)),
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                          onPressed: () => provider.resetStuckQueue(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),

                  // Node Link Simulator Buttons
                  if (provider.isUsingMock)
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        _simPill(
                          label: provider.isConnected ? 'DISCONNECT' : 'CONNECT P1',
                          color: provider.isConnected
                              ? const Color(0xFFEF4444)
                              : const Color(0xFF10B981),
                          onTap: () {
                            if (provider.isConnected) {
                              provider.disconnectFromNode();
                            } else {
                              provider.connectToNode('NODE-P1');
                            }
                          },
                        ),
                        _simPill(
                          label: 'SIM INCOMING TXT',
                          color: const Color(0xFF38BDF8),
                          onTap: () {
                            provider.simulateIncomingMessage(
                              text:
                                  'Relayed from base camp across 5 km LoRa mesh.',
                            );
                          },
                        ),
                        _simPill(
                          label: 'SIM VOICE MAIL',
                          color: const Color(0xFFA855F7),
                          onTap: () {
                            provider.simulateIncomingVoiceMail();
                          },
                        ),
                        _simPill(
                          label: 'SIM ACK DELIVERED',
                          color: const Color(0xFF22C55E),
                          onTap: () {
                            // Find any in_transit message to ACK
                            final transit = allMessages
                                .where((m) => m.status == MessageStatus.inTransit)
                                .toList();
                            if (transit.isNotEmpty) {
                              provider.simulateLoRaAck(transit.first.id);
                            } else if (allMessages.isNotEmpty) {
                              provider.simulateLoRaAck(allMessages.last.id);
                            }
                          },
                        ),
                      ],
                    ),
                ],
              ),
            ),

            const Divider(height: 1, color: Colors.white12),

            // SQLite Records Inspector
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'LOCAL SQLITE RECORDS',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                      fontFamily: 'monospace',
                    ),
                  ),
                  Text(
                    '${allMessages.length} total',
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
                        'No SQLite records buffered.',
                        style: TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    )
                  : ListView.builder(
                      itemCount: allMessages.length,
                      itemBuilder: (context, index) {
                        final msg = allMessages[index];
                        return _buildRecordTile(context, provider, msg);
                      },
                    ),
            ),

            // Clear all DB button at bottom
            Padding(
              padding: const EdgeInsets.all(10),
              child: TextButton.icon(
                icon: const Icon(Icons.delete_sweep,
                    color: Colors.white38, size: 16),
                label: const Text(
                  'Wipe Local SQLite Database',
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

  Widget _simPill({
    required String label,
    required Color color,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.6)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 9.5,
            fontWeight: FontWeight.bold,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }

  Widget _buildRecordTile(
    BuildContext context,
    MessageMailProvider provider,
    MessageMail msg,
  ) {
    final isVoice = msg.payloadType == PayloadType.voiceMail;
    final byteSize = isVoice
        ? (msg.audioBlob?.length ?? 0)
        : (msg.textContent?.length ?? 0);

    Color statusColor;
    switch (msg.status) {
      case MessageStatus.pendingLocal:
        statusColor = const Color(0xFFFFB300);
        break;
      case MessageStatus.inTransit:
        statusColor = const Color(0xFF38BDF8);
        break;
      case MessageStatus.delivered:
        statusColor = const Color(0xFF4ADE80);
        break;
      case MessageStatus.failed:
        statusColor = const Color(0xFFF87171);
        break;
    }

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222E),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'ID: ${msg.id.substring(0, 8)}...',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  fontFamily: 'monospace',
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  msg.status.value,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Type: ${msg.payloadType.value} • $byteSize B',
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
              Text(
                'Retries: ${msg.retryCount}',
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          if (msg.textContent != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '"${msg.textContent}"',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white60, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

