import 'dart:async';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';

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
    final uri = Uri.parse('bankid:///?autostarttoken=$_autostart&redirect=null');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Logga in med BankID')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Provbokningsbevakning',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              const Text(
                'Logga in med BankID för att söka lediga körprovstider hos Trafikverket.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              if (_qr != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.white,
                  child: QrImageView(
                    data: _qr!,
                    size: 240,
                    backgroundColor: Colors.white,
                  ),
                )
              else if (_starting)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
              const SizedBox(height: 16),
              if (_qr == null)
                FilledButton(
                  onPressed: _starting ? null : _begin,
                  child: const Text('Starta BankID'),
                )
              else ...[
                const Text(
                  'Skanna QR-koden i BankID-appen på en annan enhet, eller öppna BankID på den här telefonen.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: _openBankIdApp,
                  child: const Text('Öppna BankID på den här enheten'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    _poll?.cancel();
                    setState(() => _qr = null);
                  },
                  child: const Text('Avbryt'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
