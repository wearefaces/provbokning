import 'package:flutter/material.dart';
import 'api.dart';
import 'screens/shell.dart';
import 'screens/login_screen.dart';
import 'theme.dart';
import 'widgets/glass.dart';

void main() {
  runApp(const ProvbokApp());
}

class ProvbokApp extends StatelessWidget {
  const ProvbokApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Provbokning',
      debugShowCheckedModeBanner: false,
      theme: buildGlassTheme(),
      builder: (context, child) =>
          GlassBackground(child: child ?? const SizedBox.shrink()),
      home: const _Bootstrap(),
    );
  }
}

class _Bootstrap extends StatefulWidget {
  const _Bootstrap();
  @override
  State<_Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<_Bootstrap> {
  ApiClient? _api;
  bool? _authed;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final api = await ApiClient.instance();
    try {
      await api.billingStatus();
    } catch (_) {/* offline tolerated */}
    final ok = await _safeIsAuthed(api);
    if (!mounted) return;
    setState(() {
      _api = api;
      _authed = ok;
    });
  }

  Future<bool> _safeIsAuthed(ApiClient api) async {
    try {
      return await api.isAuthenticated();
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = _api;
    if (api == null || _authed == null) {
      return const Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: CircularProgressIndicator(color: GlassPalette.accentSoft),
        ),
      );
    }
    if (_authed == false) {
      return LoginScreen(
        api: api,
        onAuthenticated: () => setState(() => _authed = true),
      );
    }
    return AppShell(
      api: api,
      onLogout: () => setState(() => _authed = false),
    );
  }
}
