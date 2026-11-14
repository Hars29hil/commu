import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/message_mail_provider.dart';

/// WhatsApp-style bottom composer:
/// - Type text & tap Send
/// - When text is empty: tap Mic to record (or hold) with live timer, cancel & send!
class VoiceRecorderBar extends StatefulWidget {
  final String chatId;
  final bool isGroup;

  const VoiceRecorderBar({
    super.key,
    required this.chatId,
    this.isGroup = false,
  });

  @override
  State<VoiceRecorderBar> createState() => _VoiceRecorderBarState();
}

class _VoiceRecorderBarState extends State<VoiceRecorderBar>
    with SingleTickerProviderStateMixin {
  final TextEditingController _textController = TextEditingController();
  bool _hasText = false;
  bool _isRecording = false;
  int _recordSeconds = 0;
  Timer? _recordTimer;
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    )..repeat(reverse: true);
    _textController.addListener(() {
      final nonEmpty = _textController.text.trim().isNotEmpty;
      if (nonEmpty != _hasText) {
        setState(() => _hasText = nonEmpty);
      }
    });
  }

  Future<void> _startRecord() async {
    if (_isRecording) return;
    final provider = context.read<MessageMailProvider>();
    final started = await provider.audio.startRecording();
    if (!started) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Microphone permission is required to record voice.')),
        );
      }
      return;
    }

    setState(() {
      _isRecording = true;
      _recordSeconds = 0;
    });

    _recordTimer?.cancel();
    _recordTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _recordSeconds++);
      }
    });
  }

  Future<void> _stopAndSendRecord() async {
    _recordTimer?.cancel();
    final provider = context.read<MessageMailProvider>();
    setState(() => _isRecording = false);

    final voice = await provider.audio.stopRecording();
    if (voice != null && voice.bytes.isNotEmpty) {
      await provider.sendVoiceMail(
        widget.chatId,
        voice,
        isGroup: widget.isGroup,
      );
    }
  }

  Future<void> _cancelRecord() async {
    _recordTimer?.cancel();
    final provider = context.read<MessageMailProvider>();
    setState(() => _isRecording = false);
    await provider.audio.cancelRecording();
  }

  void _sendTextMessage() {
    final text = _textController.text.trim();
    if (text.isEmpty) return;

    final provider = context.read<MessageMailProvider>();
    provider.sendTextMessage(
      widget.chatId,
      text,
      isGroup: widget.isGroup,
    );
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
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0xFF0B141A),
        border: Border(top: BorderSide(color: Colors.white10)),
      ),
      child: SafeArea(
        top: false,
        child: _isRecording ? _buildRecordingUi() : _buildInputUi(),
      ),
    );
  }

  Widget _buildRecordingUi() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF1F2C34),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(color: const Color(0xFFEF4444).withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (context, _) {
              return Container(
                width: 11,
                height: 11,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEF4444)
                          .withValues(alpha: 0.3 + 0.6 * _pulseController.value),
                      blurRadius: 8,
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(width: 10),
          Text(
            '${_recordSeconds ~/ 60}:${(_recordSeconds % 60).toString().padLeft(2, '0')}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 24,
              child: AnimatedBuilder(
                animation: _pulseController,
                builder: (context, _) {
                  return Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: List.generate(16, (i) {
                      final val = (sin(i * 0.9 + _pulseController.value * 4) + 1) / 2;
                      return Container(
                        width: 3,
                        height: (val * 20).clamp(4.0, 22.0),
                        decoration: BoxDecoration(
                          color: const Color(0xFF25D366),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      );
                    }),
                  );
                },
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white70),
            tooltip: 'Cancel recording',
            onPressed: _cancelRecord,
          ),
          GestureDetector(
            onTap: _stopAndSendRecord,
            child: Container(
              width: 38,
              height: 38,
              decoration: const BoxDecoration(
                color: Color(0xFF25D366),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.black, size: 19),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputUi() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: TextField(
            controller: _textController,
            style: const TextStyle(color: Colors.white, fontSize: 15),
            minLines: 1,
            maxLines: 4,
            textInputAction: TextInputAction.send,
            onSubmitted: (_) => _sendTextMessage(),
            decoration: InputDecoration(
              hintText: 'Message...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 15),
              filled: true,
              fillColor: const Color(0xFF1F2C34),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(24),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (_hasText)
          GestureDetector(
            onTap: _sendTextMessage,
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                color: Color(0xFF00A884),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.send, color: Colors.white, size: 21),
            ),
          )
        else
          GestureDetector(
            onTap: _startRecord,
            onLongPressStart: (_) => _startRecord(),
            onLongPressEnd: (_) => _stopAndSendRecord(),
            child: Container(
              width: 46,
              height: 46,
              decoration: const BoxDecoration(
                color: Color(0xFF00A884),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.mic, color: Colors.white, size: 23),
            ),
          ),
      ],
    );
  }
}
