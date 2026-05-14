import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../theme.dart';
import '../widgets/glass.dart';

class LoginScreen extends StatefulWidget {
  final ApiClient api;
  final VoidCallback onAuthenticated;

  const LoginScreen({
    super.key,
    required this.api,
    required this.onAuthenticated,
  });

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  String? _qr;
  String? _autostart;
  String? _error;
  bool _starting = false;
  Timer? _poll;

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _begin() async {
    setState(() {
      _starting = true;
      _error = null;
      _qr = null;
    });
    try {
      final r = await widget.api.beginBankId();
      if (!mounted) return;
      setState(() {
        _qr = r.qrCode;
        _autostart = r.autostartToken;
        _starting = false;
      });
      _startPoll();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _starting = false;
      });
    }
  }

  void _startPoll() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) async {
      try {
        final s = await widget.api.pollBankId();
        if (!mounted) return;
        if (s.state == 'complete') {
          _poll?.cancel();
          widget.onAuthenticated();
        } else if (s.qrCode != null && s.qrCode!.isNotEmpty) {
          setState(() => _qr = s.qrCode);
        } else if (s.state == 'error') {
          _poll?.cancel();
          setState(() => _error = s.error ?? 'Okänt fel');
        }
      } catch (_) {/* ignore transient poll errors */}
    });
  }

  Future<void> _openBankIdApp() async {
    if (_autostart == null) return;
    final uri =
        Uri.parse('bankid:///?autostarttoken=$_autostart&redirect=null');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 12),
              Center(
                child: Container(
                  width: 64,
                  height: 64,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [
                        GlassPalette.accent,
                        GlassPalette.accentSoft,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: [
                      BoxShadow(
                        color: GlassPalette.accent.withOpacity(0.45),
                        blurRadius: 24,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: const Icon(Icons.directions_car_filled,
                      color: Colors.white, size: 30),
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                'Provbokning',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                'Hitta lediga körprovstider hos Trafikverket',
                textAlign: TextAlign.center,
                style: TextStyle(color: GlassPalette.textSecondary),
              ),
              const SizedBox(height: 28),
              GlassPanel(
                padding: const EdgeInsets.all(22),
                child: Column(
                  children: [
                    const Text(
                      'Logga in med BankID',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 14),
                    if (_qr != null)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: QrImageView(
                          data: _qr!,
                          size: 220,
                          backgroundColor: Colors.white,
                        ),
                      )
                    else if (_starting)
                      const Padding(
                        padding: EdgeInsets.all(40),
                        child: CircularProgressIndicator(
                            color: GlassPalette.accentSoft),
                      )
                    else
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        child: Icon(Icons.qr_code_2_rounded,
                            size: 96,
                            color: Colors.white.withOpacity(0.35)),
                      ),
                    const SizedBox(height: 18),
                    if (_qr == null)
                      GlassButton(
                        label: 'Starta BankID',
                        icon: Icons.fingerprint,
                        onPressed: _starting ? null : _begin,
                        loading: _starting,
                        expand: true,
                      )
                    else ...[
                      const Text(
                        'Skanna QR-koden i BankID-appen, eller öppna BankID på den här enheten.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: GlassPalette.textSecondary, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      GlassButton(
                        label: 'Öppna BankID här',
                        icon: Icons.open_in_new,
                        onPressed: _openBankIdApp,
                        primary: false,
                        expand: true,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () {
                          _poll?.cancel();
                          setState(() => _qr = null);
                        },
                        style: TextButton.styleFrom(
                          foregroundColor: GlassPalette.textSecondary,
                        ),
                        child: const Text('Avbryt'),
                      ),
                    ],
                  ],
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 14),
                GlassPanel(
                  tint: GlassPalette.danger,
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Colors.white),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
