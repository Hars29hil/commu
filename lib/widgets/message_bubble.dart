import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message_mail.dart';
import '../providers/message_mail_provider.dart';
import '../services/audio_service.dart';

/// WhatsApp-style message bubble supporting Text, Real Voice Notes (with duration/progress),
/// Group sender attribution, Call logs, and delivery checkmarks.
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

    if (message.payloadType == PayloadType.callLog) {
      return _buildCallLogPill();
    }

    final isVoice = message.payloadType == PayloadType.voiceMail;
    final isPlaying = provider.audio.isPlaying &&
        provider.audio.currentlyPlayingId == message.id;

    final bubbleBg = isOutgoing
        ? const Color(0xFF005C4B) // WhatsApp dark outgoing teal
        : const Color(0xFF1F2C34); // WhatsApp dark incoming slate

    return Align(
      alignment: isOutgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: EdgeInsets.only(
          left: isOutgoing ? 56 : 12,
          right: isOutgoing ? 12 : 56,
          top: 4,
          bottom: 4,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: bubbleBg,
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(14),
            topRight: const Radius.circular(14),
            bottomLeft: Radius.circular(isOutgoing ? 14 : 3),
            bottomRight: Radius.circular(isOutgoing ? 3 : 14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 3,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment:
              isOutgoing ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            if (!isOutgoing && message.isGroup) ...[
              Text(
                provider.resolveDisplayName(message.senderId),
                style: TextStyle(
                  color: _colorForSender(message.senderId),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
            ],
            if (isVoice)
              _buildVoiceMailPlayer(context, provider, isPlaying)
            else
              Text(
                message.textContent ?? '',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.32,
                ),
              ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _formatTime(message.timestamp),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 10.5,
                  ),
                ),
                if (isOutgoing) ...[
                  const SizedBox(width: 5),
                  _buildStatusTick(message.status),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCallLogPill() {
    final text = message.textContent ?? 'Voice call';
    final isMissed = text.toLowerCase().contains('unanswered') ||
        text.toLowerCase().contains('missed') ||
        text.toLowerCase().contains('declined');

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 20),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: const Color(0xFF182229),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isMissed
                ? const Color(0xFFEF4444).withValues(alpha: 0.4)
                : Colors.white12,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isMissed ? Icons.call_missed : Icons.call,
              size: 14,
              color: isMissed ? const Color(0xFFF87171) : const Color(0xFF00E676),
            ),
            const SizedBox(width: 6),
            Text(
              '$text • ${_formatTime(message.timestamp)}',
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildVoiceMailPlayer(
    BuildContext context,
    MessageMailProvider provider,
    bool isPlaying,
  ) {
    final blob = message.audioBlob;
    final waveform = AudioService.extractWaveform(blob, barCount: 24);
    final totalMs = message.durationMs > 0
        ? message.durationMs
        : (isPlaying && provider.audio.currentDuration.inMilliseconds > 0
            ? provider.audio.currentDuration.inMilliseconds
            : 2000);
    final posMs = isPlaying ? provider.audio.currentPosition.inMilliseconds : 0;
    final progress = totalMs > 0 ? (posMs / totalMs).clamp(0.0, 1.0) : 0.0;

    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              GestureDetector(
                onTap: () {
                  if (blob != null && blob.isNotEmpty) {
                    provider.audio.playVoiceNote(
                      messageId: message.id,
                      blob: blob,
                      codecType: message.codecType,
                    );
                  }
                },
                child: Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isPlaying
                        ? const Color(0xFFEF4444)
                        : const Color(0xFF25D366),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: 28,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: List.generate(waveform.length, (i) {
                          final barProgress = (i + 1) / waveform.length;
                          final active = isPlaying && barProgress <= progress;
                          return Container(
                            width: 3,
                            height: (waveform[i] * 26).clamp(4.0, 26.0),
                            decoration: BoxDecoration(
                              color: active
                                  ? const Color(0xFF25D366)
                                  : Colors.white54,
                              borderRadius: BorderRadius.circular(2),
                            ),
                          );
                        }),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          isPlaying
                              ? _formatDuration(posMs)
                              : _formatDuration(totalMs),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 10.5,
                          ),
                        ),
                        Text(
                          '${((blob?.length ?? 0) / 1024).toStringAsFixed(1)} KB',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStatusTick(MessageStatus status) {
    switch (status) {
      case MessageStatus.pendingLocal:
        return Icon(Icons.access_time,
            size: 13, color: Colors.white.withValues(alpha: 0.65));
      case MessageStatus.inTransit:
        return Icon(Icons.done,
            size: 14, color: Colors.white.withValues(alpha: 0.75));
      case MessageStatus.delivered:
        return const Icon(Icons.done_all, size: 15, color: Color(0xFF53BDEB));
      case MessageStatus.failed:
        return const Icon(Icons.error_outline,
            size: 14, color: Color(0xFFF87171));
    }
  }

  Color _colorForSender(String name) {
    const palette = [
      Color(0xFF53BDEB),
      Color(0xFF25D366),
      Color(0xFFF59E0B),
      Color(0xFFE879F9),
      Color(0xFF38BDF8),
      Color(0xFFFB7185),
    ];
    final hash = name.codeUnits.fold<int>(0, (acc, c) => acc + c);
    return palette[hash % palette.length];
  }

  String _formatDuration(int ms) {
    final totalSec = (ms / 1000).round();
    final m = totalSec ~/ 60;
    final s = totalSec % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  String _formatTime(int epochMs) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}
