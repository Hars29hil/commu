import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';
import '../services/ble_service.dart';

/// Compact live status bar showing BLE relay status, RSSI, and pending offline queue count.
class ConnectionStatusPill extends StatelessWidget {
  final bool compact;
  const ConnectionStatusPill({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final isConnected = provider.isConnected;
    final isScanning = provider.bleState == BleConnectionState.scanning;
    final isConnecting = provider.bleState == BleConnectionState.connecting;
    final pendingCount = provider.pendingSyncCount;

    Color statusColor;
    String statusText;
    String subText;
    IconData statusIcon;

    if (isConnected) {
      statusColor = const Color(0xFF00E676);
      final nodeName = provider.connectedNodeName ?? 'OFFGRID-RELAY';
      statusText = 'ONLINE • $nodeName (${provider.rssi} dBm)';
      subText = 'Mesh Live • Encrypted Compressed Link';
      statusIcon = Icons.bluetooth_connected;
    } else if (isConnecting) {
      statusColor = const Color(0xFFFFB300);
      statusText = 'CONNECTING TO RELAY...';
      subText = 'Establishing BLE GATT tunnel...';
      statusIcon = Icons.bluetooth_searching;
    } else if (isScanning) {
      statusColor = const Color(0xFF29B6F6);
      statusText = 'RADAR ACTIVE • SEARCHING...';
      subText = 'Auto-connects when relay is nearby';
      statusIcon = Icons.radar;
    } else {
      statusColor = const Color(0xFFFF5252);
      statusText = 'OFFLINE (OFFLINE CACHE ACTIVE)';
      subText = 'Queued locally • Auto-sends when in range';
      statusIcon = Icons.cloud_off;
    }

    return InkWell(
      onTap: () {
        if (isConnected) {
          provider.manualMeshSync();
        } else if (isScanning) {
          provider.bridge.stopScan();
        } else {
          provider.scanForNode();
        }
      },
      borderRadius: BorderRadius.circular(14),
      child: Container(
        margin: EdgeInsets.symmetric(
          horizontal: compact ? 12 : 14,
          vertical: compact ? 4 : 8,
        ),
        padding: EdgeInsets.symmetric(
          horizontal: 12,
          vertical: compact ? 7 : 10,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF1E222D),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: statusColor.withValues(alpha: 0.45),
            width: 1.2,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: statusColor,
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: statusColor.withValues(alpha: 0.7),
                    blurRadius: 6,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (!compact) ...[
                    const SizedBox(height: 2),
                    Text(
                      subText,
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 10,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            if (pendingCount > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF9100).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: const Color(0xFFFF9100)),
                ),
                child: Text(
                  '$pendingCount Queued',
                  style: const TextStyle(
                    color: Color(0xFFFF9100),
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
            const SizedBox(width: 6),
            Icon(statusIcon, color: statusColor, size: 18),
          ],
        ),
      ),
    );
  }
}
