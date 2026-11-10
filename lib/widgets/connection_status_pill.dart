import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';
import '../services/ble_service.dart';

/// Visual Connection Status Header Pill matching specification:
/// - DISCONNECTED (OFFLINE CACHE ACTIVE)
/// - CONNECTED TO NODE [P1..P6/C] (RSSI: -XX dBm)
/// - Node ping latency indicator and pending sync count badge
class ConnectionStatusPill extends StatelessWidget {
  const ConnectionStatusPill({super.key});

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
      statusColor = const Color(0xFF00E676); // Tactical green
      final nodeName = provider.connectedNodeName ?? 'ESP32 RELAY';
      statusText = 'ONLINE • $nodeName (RSSI: ${provider.rssi} dBm)';
      subText = 'Real-Time Mesh Live • Zero-Touch Auto Connected';
      statusIcon = Icons.bluetooth_connected;
    } else if (isConnecting) {
      statusColor = const Color(0xFFFFB300); // Amber
      statusText = 'CONNECTING TO ESP32 RELAY...';
      subText = 'Locking onto radar beacon & establishing link...';
      statusIcon = Icons.bluetooth_searching;
    } else if (isScanning) {
      statusColor = const Color(0xFF29B6F6); // Cyan
      statusText = 'RADAR ACTIVE • LOOKING FOR RELAY...';
      subText = 'Auto-connects immediately when within range';
      statusIcon = Icons.radar;
    } else {
      statusColor = const Color(0xFFFF5252); // Alert red
      statusText = 'OFFLINE • DISCONNECTED (OFFLINE CACHE ACTIVE)';
      subText = 'Messages stored in SQLite • Auto-delivered when in range';
      statusIcon = Icons.cloud_off;
    }

    return InkWell(
      onTap: () {
        if (isConnected) {
          provider.disconnectFromNode();
        } else if (isScanning) {
          provider.bridge.stopScan();
        } else {
          provider.scanForNode();
        }
      },
      borderRadius: BorderRadius.circular(16),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: statusColor.withValues(alpha: 0.5),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: statusColor.withValues(alpha: 0.15),
            blurRadius: 10,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          Row(
            children: [
              // Pulsing indicator dot
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: statusColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: statusColor,
                      blurRadius: 6,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Main status text
              Expanded(
                child: Text(
                  statusText,
                  style: TextStyle(
                    color: statusColor,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // Icon
              Icon(statusIcon, color: statusColor, size: 20),
            ],
          ),
          const SizedBox(height: 6),
          // Sub-bar with Ping Latency & Pending Sync Count Badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Sub-status info
              Expanded(
                child: Row(
                  children: [
                    Icon(
                      isConnected ? Icons.sensors : Icons.radar,
                      size: 13,
                      color: isConnected ? const Color(0xFF00E676) : Colors.white38,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        subText,
                        style: TextStyle(
                          color: isConnected ? Colors.white70 : Colors.white38,
                          fontSize: 10.5,
                          fontFamily: 'monospace',
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              // Pending Sync Count Badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: pendingCount > 0
                      ? const Color(0xFFFF9100).withValues(alpha: 0.25)
                      : Colors.white10,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: pendingCount > 0
                        ? const Color(0xFFFF9100)
                        : Colors.white24,
                    width: 1,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      pendingCount > 0
                          ? Icons.hourglass_top
                          : Icons.check_circle_outline,
                      size: 11,
                      color: pendingCount > 0
                          ? const Color(0xFFFF9100)
                          : const Color(0xFF00E676),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '$pendingCount Pending',
                      style: TextStyle(
                        color: pendingCount > 0
                            ? const Color(0xFFFF9100)
                            : Colors.white70,
                        fontSize: 10.5,
                        fontWeight: FontWeight.bold,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ),);
  }
}

