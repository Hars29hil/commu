import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../protocol/ble_packet_codec.dart';
import '../providers/message_mail_provider.dart';

/// One-time onboarding screen asking only for the user's unique name.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _nameController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  String _handlePreview = '';
  bool _isSaving = false;
  bool _ignoringBattery = true;

  @override
  void initState() {
    super.initState();
    _nameController.addListener(() {
      setState(() {
        _handlePreview = BlePacketCodec.normalizeUsername(_nameController.text);
      });
    });
    _checkBatteryOpt();
  }

  Future<void> _checkBatteryOpt() async {
    final provider = context.read<MessageMailProvider>();
    final ignoring = await provider.nativePlatform.isIgnoringBatteryOptimizations();
    if (mounted) {
      setState(() => _ignoringBattery = ignoring);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);
    final provider = context.read<MessageMailProvider>();
    final ok = await provider.registerUsername(_nameController.text);
    if (mounted) {
      setState(() => _isSaving = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter at least 2 letters or numbers.')),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B141A),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Center(
                    child: Container(
                      width: 84,
                      height: 84,
                      decoration: BoxDecoration(
                        color: const Color(0xFF00A884).withValues(alpha: 0.16),
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: const Color(0xFF00A884).withValues(alpha: 0.5),
                          width: 2,
                        ),
                      ),
                      child: const Icon(
                        Icons.cell_tower,
                        color: Color(0xFF25D366),
                        size: 42,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    'Welcome to Off-Grid Mail',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Enter your unique name. Nearby users on the off-grid relay will find you automatically by name—no internet, SIM card, or manual pairing needed.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white60,
                      fontSize: 13.5,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _nameController,
                    autofocus: true,
                    textCapitalization: TextCapitalization.words,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                    decoration: InputDecoration(
                      labelText: 'Your Unique Name',
                      labelStyle: const TextStyle(color: Color(0xFF25D366)),
                      hintText: 'e.g. Harshil',
                      hintStyle: const TextStyle(color: Colors.white30),
                      prefixIcon: const Icon(Icons.person_outline, color: Color(0xFF00A884)),
                      filled: true,
                      fillColor: const Color(0xFF1F2C34),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(color: Color(0xFF00A884), width: 1.5),
                      ),
                    ),
                    validator: (val) {
                      final norm = BlePacketCodec.normalizeUsername(val ?? '');
                      if (norm.length < 2) {
                        return 'Enter at least 2 letters or numbers';
                      }
                      return null;
                    },
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  if (_handlePreview.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      'Mesh ID: @$_handlePreview',
                      style: const TextStyle(
                        color: Color(0xFF53BDEB),
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                  if (!_ignoringBattery) ...[
                    const SizedBox(height: 20),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1F2C34),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.notifications_active_outlined,
                              color: Color(0xFF25D366), size: 22),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              'Allow unrestricted background mode so calls & messages arrive even when screen is off.',
                              style: TextStyle(color: Colors.white70, fontSize: 12),
                            ),
                          ),
                          TextButton(
                            onPressed: () async {
                              final p = context.read<MessageMailProvider>();
                              await p.nativePlatform.requestIgnoreBatteryOptimizations();
                              await Future.delayed(const Duration(milliseconds: 800));
                              _checkBatteryOpt();
                            },
                            child: const Text('ALLOW',
                                style: TextStyle(color: Color(0xFF25D366))),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 28),
                  ElevatedButton(
                    onPressed: _isSaving ? null : _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF00A884),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Text(
                            'Continue to Chats',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

