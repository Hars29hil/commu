import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message_mail.dart';
import '../providers/message_mail_provider.dart';
import '../services/audio_service.dart';

/// Renders a message mail item in the conversation stream:
/// Handles both Text messages and Voice Mail compressed audio playback.
/// Displays tactical message status badges:
/// ⏳ Local Queue | 📡 Relaying on Mesh | ✅ Delivered | ❌ Failed
class MessageBubble extends StatelessWidget {
  final MessageMail message;
  final bool isOutgoing;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isOutgoing,
  });

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final isVoice = message.payloadType == PayloadType.voiceMail;
    final isPlaying = provider.audio.isPlaying &&
        provider.audio.currentlyPlayingId == message.id;

    final bubbleBg = isOutgoing
        ? const Color(0xFF1E3A5F) // Tactical Navy
        : const Color(0xFF232936); // Dark Slate

    final bubbleBorder = isOutgoing
        ? const Color(0xFF3B82F6).withValues(alpha: 0.4)
        : Colors.white12;

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.80,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleBg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isOutgoing ? 16 : 4),
            bottomRight: Radius.circular(isOutgoing ? 4 : 16),
          ),
          border: Border.all(color: bubbleBorder),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            // Sender / Node Header
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isOutgoing ? Icons.arrow_upward : Icons.arrow_downward,
                  size: 11,
                  color: isOutgoing ? const Color(0xFF60A5FA) : const Color(0xFF4ADE80),
                ),
                const SizedBox(width: 4),
                Text(
                  isOutgoing
                      ? 'TO: ${message.recipientId}'
                      : 'FROM: ${message.senderId}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10.5,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Content: Voice Mail or Text
            if (isVoice)
              _buildVoiceMailPlayer(context, provider, isPlaying)
            else
              _buildTextContent(),

            const SizedBox(height: 8),

            // Timestamp and Status Badge Footer
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(message.timestamp),
                  style: const TextStyle(
                    color: Colors.white38,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
                _buildStatusBadge(message.status),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTextContent() {
    return Text(
      message.textContent ?? '',
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14.5,
        height: 1.35,
      ),
    );
  }

  Widget _buildVoiceMailPlayer(
    BuildContext context,
    MessageMailProvider provider,
    bool isPlaying,
  ) {
    final blob = message.audioBlob;
    final byteSize = blob?.length ?? 0;
    final waveform = AudioService.extractWaveform(blob, barCount: 22);

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Play/Pause circular button
              GestureDetector(
                onTap: () {
                  if (blob != null && blob.isNotEmpty) {
                    provider.audio.playAudioBlob(message.id, blob);
                  }
                },
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isPlaying
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF3B82F6),
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (isPlaying
                                ? const Color(0xFFEF4444)
                                : const Color(0xFF3B82F6))
                            .withValues(alpha: 0.4),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              // Waveform bars
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: waveform.map((amp) {
                      return Container(
                        width: 3,
                        height: (amp * 28).clamp(4.0, 28.0),
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? const Color(0xFF60A5FA)
                              : Colors.white54,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Codec2 payload info
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  const Icon(Icons.mic, size: 11, color: Color(0xFF60A5FA)),
                  const SizedBox(width: 4),
                  Text(
                    'Codec2 Voice Mail • $byteSize B',
                    style: const TextStyle(
                      color: Color(0xFF93C5FD),
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const Text(
                '8 kHz Mono',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(MessageStatus status) {
    String label;
    Color color;

    switch (status) {
      case MessageStatus.pendingLocal:
        label = '⏳ Local Queue';
        color = const Color(0xFFFFB300); // Amber
        break;
      case MessageStatus.inTransit:
        label = '📡 Relaying on Mesh';
        color = const Color(0xFF38BDF8); // Cyan
        break;
      case MessageStatus.delivered:
        label = '✅ Delivered';
        color = const Color(0xFF4ADE80); // Green
        break;
      case MessageStatus.failed:
        label = '❌ Failed';
        color = const Color(0xFFF87171); // Red
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w700,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  String _formatTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

