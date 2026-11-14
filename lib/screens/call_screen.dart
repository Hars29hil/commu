import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/message_mail.dart';
import '../providers/message_mail_provider.dart';

/// Full-screen overlay for Outgoing, Incoming, Live Connected Calls,
/// and the Unanswered Voicemail Fallback Prompt + Recorder.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen>
    with SingleTickerProviderStateMixin {
  Timer? _tickTimer;
  int _elapsedSec = 0;
  bool _isRecordingVm = false;
  int _vmSec = 0;
  late AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
    _tickTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final provider = context.read<MessageMailProvider>();
      final st = provider.callState;
      if (st.phase == CallPhase.connected && st.connectedAtMs != null) {
        setState(() {
          _elapsedSec =
              ((DateTime.now().millisecondsSinceEpoch - st.connectedAtMs!) /
                      1000)
                  .floor();
        });
      } else if (_isRecordingVm) {
        setState(() => _vmSec++);
      }
    });
  }

  @override
  void dispose() {
    _tickTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  Future<void> _startVoicemailRecording(MessageMailProvider provider) async {
    provider.openVoicemailRecorderAfterMissedCall();
    final ok = await provider.audio.startRecording();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Microphone permission required.')),
      );
      return;
    }
    setState(() {
      _isRecordingVm = true;
      _vmSec = 0;
    });
  }

  Future<void> _sendVoicemail(MessageMailProvider provider) async {
    setState(() => _isRecordingVm = false);
    final voice = await provider.audio.stopRecording();
    if (voice != null && voice.bytes.isNotEmpty) {
      await provider.sendVoicemailFromMissedCall(voice);
    } else {
      await provider.cutUnansweredCall();
    }
  }

  Future<void> _cancelVoicemail(MessageMailProvider provider) async {
    setState(() => _isRecordingVm = false);
    await provider.audio.cancelRecording();
    await provider.cutUnansweredCall();
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MessageMailProvider>();
    final call = provider.callState;
    final peerName = call.peerDisplayName ?? call.peerUsername ?? 'Unknown';

    return PopScope(
      canPop: false,
      child: Material(
        color: const Color(0xFF0B141A),
        child: SafeArea(
          child: Column(
          children: [
            const SizedBox(height: 28),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.cell_tower, color: Color(0xFF25D366), size: 16),
                SizedBox(width: 6),
                Text(
                  'OFF-GRID MESH CALL',
                  style: TextStyle(
                    color: Color(0xFF25D366),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.4,
                  ),
                ),
              ],
            ),
            const Spacer(flex: 1),

            // Pulsing Avatar
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (_, child) {
                final spread =
                    (call.phase == CallPhase.incoming ||
                        call.phase == CallPhase.calling ||
                        call.phase == CallPhase.ringing)
                    ? 8.0 + 18.0 * _pulseCtrl.value
                    : 4.0;
                return Container(
                  padding: EdgeInsets.all(spread),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF00A884).withValues(alpha: 0.14),
                  ),
                  child: child,
                );
              },
              child: CircleAvatar(
                radius: 56,
                backgroundColor: const Color(0xFF1F2C34),
                child: Text(
                  peerName.substring(0, 1).toUpperCase(),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 44,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              peerName,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _statusSubtitle(call),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: call.phase == CallPhase.connected
                    ? const Color(0xFF25D366)
                    : Colors.white70,
                fontSize: 15.5,
              ),
            ),

            const Spacer(flex: 2),

            // Bottom Action Zone depending on CallPhase
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: _buildPhaseControls(provider, call),
            ),
          ],
        ),
      ),
    ),
  );
  }

  String _statusSubtitle(CallSessionState call) {
    switch (call.phase) {
      case CallPhase.calling:
        return 'Calling over BLE relay...';
      case CallPhase.ringing:
        return 'Ringing...';
      case CallPhase.incoming:
        return 'Incoming voice call...';
      case CallPhase.connected:
        final m = _elapsedSec ~/ 60;
        final s = _elapsedSec % 60;
        return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')} • Compressed ADPCM';
      case CallPhase.unansweredPrompt:
        return call.endReason ?? 'User did not answer.';
      case CallPhase.recordingVoicemail:
        final m = _vmSec ~/ 60;
        final s = _vmSec % 60;
        return 'Recording Voicemail  $m:${s.toString().padLeft(2, '0')}';
      case CallPhase.idle:
        return '';
    }
  }

  Widget _buildPhaseControls(
    MessageMailProvider provider,
    CallSessionState call,
  ) {
    switch (call.phase) {
      case CallPhase.calling:
      case CallPhase.ringing:
        return _buildInCallControls(provider, call);

      case CallPhase.incoming:
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _circleBtn(
              icon: Icons.call_end,
              color: const Color(0xFFEF4444),
              label: 'Decline',
              onTap: () => provider.declineIncomingCall(),
            ),
            _circleBtn(
              icon: Icons.call,
              color: const Color(0xFF25D366),
              label: 'Answer',
              onTap: () => provider.acceptIncomingCall(),
            ),
          ],
        );

      case CallPhase.connected:
        return _buildInCallControls(provider, call);

      case CallPhase.unansweredPrompt:
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2C34),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            children: [
              const Text(
                'Would you like to leave a compressed voicemail instead?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.call_end),
                      label: const Text('Cut Call'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFF87171),
                        side: const BorderSide(color: Color(0xFFEF4444)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => provider.cutUnansweredCall(),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      icon: const Icon(Icons.mic),
                      label: const Text('Record Voicemail'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF00A884),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                      onPressed: () => _startVoicemailRecording(provider),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );

      case CallPhase.recordingVoicemail:
        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: const Color(0xFF1F2C34),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFFEF4444)),
          ),
          child: Column(
            children: [
              SizedBox(
                height: 36,
                child: AnimatedBuilder(
                  animation: _pulseCtrl,
                  builder: (_, child) {
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: List.generate(20, (i) {
                        final v = (sin(i * 0.7 + _pulseCtrl.value * 5) + 1) / 2;
                        return Container(
                          width: 4,
                          height: (v * 30).clamp(6.0, 32.0),
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
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _circleBtn(
                    icon: Icons.close,
                    color: const Color(0xFFEF4444),
                    label: 'Cut / Cancel',
                    onTap: () => _cancelVoicemail(provider),
                  ),
                  _circleBtn(
                    icon: Icons.send,
                    color: const Color(0xFF25D366),
                    label: 'Send Voicemail',
                    onTap: () => _sendVoicemail(provider),
                  ),
                ],
              ),
            ],
          ),
        );

      case CallPhase.idle:
        return const SizedBox.shrink();
    }
  }

  Widget _buildInCallControls(
    MessageMailProvider provider,
    CallSessionState call,
  ) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            _circleBtn(
              icon: call.isMuted ? Icons.mic_off : Icons.mic,
              color: call.isMuted ? Colors.white : const Color(0xFF1F2C34),
              iconColor: call.isMuted ? Colors.black : Colors.white,
              label: call.isMuted ? 'Unmute' : 'Mute',
              onTap: () => provider.toggleCallMute(),
            ),
            _circleBtn(
              icon: call.isSpeakerOn ? Icons.volume_up : Icons.hearing,
              color: call.isSpeakerOn ? Colors.white : const Color(0xFF1F2C34),
              iconColor: call.isSpeakerOn ? Colors.black : Colors.white,
              label: 'Speaker',
              onTap: () => provider.toggleCallSpeaker(),
            ),
            _circleBtn(
              icon: Icons.call_end,
              color: const Color(0xFFEF4444),
              label: 'End Call',
              onTap: () => provider.endActiveCall(),
            ),
          ],
        ),
      ],
    );
  }

  Widget _circleBtn({
    required IconData icon,
    required Color color,
    Color iconColor = Colors.white,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: iconColor, size: 28),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
