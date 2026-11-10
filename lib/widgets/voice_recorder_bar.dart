import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';

/// Push-To-Talk / Hold-to-Record interface for voice mail with audio visualizer waveform.
class VoiceRecorderBar extends StatefulWidget {
  const VoiceRecorderBar({super.key});

  @override
  State<VoiceRecorderBar> createState() => _VoiceRecorderBarState();
}

class _VoiceRecorderBarState extends State<VoiceRecorderBar>
    with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..repeat(reverse: true);
  }

  void _startRecord() async {
    final provider = context.read<MessageMailProvider>();
    setState(() {
      _isRecording = true;
      _recordSeconds = 0;
    });

    _recordTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _recordSeconds++;
        });
      }
    });

    await provider.audio.startRecording();
  }

  void _stopAndSendRecord() async {
    _recordTimer?.cancel();
    final provider = context.read<MessageMailProvider>();

    setState(() {
      _isRecording = false;
    });

    // Obtain compressed Codec2 voice blob
    final voiceBlob = await provider.audio.stopRecording();
    await provider.sendVoiceMail(voiceBlob);
  }

  void _cancelRecord() async {
    _recordTimer?.cancel();
    final provider = context.read<MessageMailProvider>();
    setState(() {
      _isRecording = false;
    });
    await provider.audio.cancelRecording();
  }

  void _sendTextMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final provider = context.read<MessageMailProvider>();
    provider.sendTextMessage(text);
    _textController.clear();
  }

  @override
  void dispose() {
    _recordTimer?.cancel();
    _pulseController.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF171A21),
        border: Border(top: BorderSide(color: Colors.white12)),
      ),
      child: SafeArea(
        child: _isRecording ? _buildRecordingUi() : _buildInputUi(),
      ),
    );
  }

  Widget _buildRecordingUi() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF2D1616),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: const Color(0xFFEF4444)),
      ),
      child: Row(
        children: [
          // Blinking recording dot
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, child) {
              return Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEF4444)
                          .withValues(alpha: 0.3 + 0.6 * _pulseController.value),
                      blurRadius: 8,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          // Timer
          Text(
            '0:${_recordSeconds.toString().padLeft(2, '0')}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 14),
          // Live Waveform visualizer
          Expanded(
            child: SizedBox(
              height: 24,
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, child) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: List.generate(18, (i) {
                      final val = (sin(i * 0.8 + _pulseController.value * 4) + 1) / 2;
                      final h = (val * 20).clamp(4.0, 24.0);
                      return Container(
                        width: 3,
                        height: h,
                        decoration: BoxDecoration(
                          color: const Color(0xFFEF4444),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  );
                },
              ),
            ),
          ),
          // Cancel button
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white70),
            tooltip: 'Cancel',
            onPressed: _cancelRecord,
          ),
          // Release / Send button
          IconButton(
            icon: const Icon(Icons.send, color: Color(0xFF00E676)),
            tooltip: 'Send Voice Mail',
            onPressed: _stopAndSendRecord,
          ),
        ],
      ),
    );
  }

  Widget _buildInputUi() {
    return Row(
      children: [
        // Hold-to-Record / Push-To-Talk Microphone button
        GestureDetector(
          onLongPressStart: (_) => _startRecord(),
          onLongPressEnd: (_) => _stopAndSendRecord(),
          child: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: const Color(0xFF262C3A),
              shape: BoxShape.circle,
              border: Border.all(color: const Color(0xFF3B82F6).withValues(alpha: 0.5)),
            ),
            child: const Icon(
              Icons.mic,
              color: Color(0xFF60A5FA),
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 8),

        // Text input field
        Expanded(
          child: TextField(
            controller: _textController,
            style: const TextStyle(color: Colors.white, fontSize: 14.5),
            decoration: InputDecoration(
              hintText: 'Offline message mail...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13.5),
              filled: true,
              fillColor: const Color(0xFF1E222D),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(20),
                borderSide: BorderSide.none,
              ),
            ),
            onSubmitted: (_) => _sendTextMessage(),
          ),
        ),
        const SizedBox(width: 8),

        // Send Text Button
        IconButton(
          icon: const Icon(Icons.arrow_upward_rounded),
          color: const Color(0xFF3B82F6),
          style: IconButton.styleFrom(
            backgroundColor: const Color(0xFF1E3A5F),
          ),
          onPressed: _sendTextMessage,
        ),
      ],
    );
  }
}

