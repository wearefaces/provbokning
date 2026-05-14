import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/glass.dart';

class ScanScreen extends StatefulWidget {
  final ApiClient api;
  final VoidCallback onLogout;

  const ScanScreen({super.key, required this.api, required this.onLogout});

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  BillingStatus? _billing;
  List<Slot> _times = [];
  List<Slot> _added = [];
  bool _scanning = false;
  bool _autoScan = false;
  Timer? _scanTimer;
  String? _error;
  Slot? _verifyingSlot;
  bool? _verifyResult;
  DateTime? _lastScan;

  @override
  void initState() {
    super.initState();
    _refreshBilling();
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    super.dispose();
  }

  Future<void> _refreshBilling() async {
    try {
      final b = await widget.api.billingStatus();
      if (mounted) setState(() => _billing = b);
    } catch (_) {/* ignore */}
  }

  Future<void> _scanOnce() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _error = null;
    });
    try {
      final r = await widget.api.scan();
      if (!mounted) return;
      setState(() {
        _times = r.times;
        _added = r.added;
        _scanning = false;
        _lastScan = DateTime.now();
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message == 'not_authenticated'
            ? 'Sessionen har gått ut. Logga in igen.'
            : 'Skanningsfel: ${e.message}';
        _scanning = false;
      });
      if (e.message == 'not_authenticated') widget.onLogout();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Nätverksfel: $e';
        _scanning = false;
      });
    }
  }

  void _toggleAutoScan() {
    setState(() => _autoScan = !_autoScan);
    if (_autoScan) {
      _scanOnce();
      _scanTimer =
          Timer.periodic(const Duration(seconds: 30), (_) => _scanOnce());
    } else {
      _scanTimer?.cancel();
    }
  }

  Future<void> _onBoka(Slot slot) async {
    setState(() {
      _verifyingSlot = slot;
      _verifyResult = null;
    });
    try {
      await widget.api.reserve(slot);
      final url = _buildBookingUrl(slot);
      if (url != null) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      final ok = await widget.api.verifySlot(slot);
      if (mounted) setState(() => _verifyResult = ok);
    } on PaymentRequiredException catch (e) {
      if (!mounted) return;
      setState(() => _verifyingSlot = null);
      _showPaywall(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _verifyingSlot = null);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Fel: $e')));
    }
  }

  String? _buildBookingUrl(Slot s) {
    final loc = s.locationId ?? 0;
    return 'https://fp.trafikverket.se/Boka/#/search///5/12/$loc/2';
  }

  Future<void> _showPaywall(String message) async {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _Paywall(
        message: message,
        billing: _billing,
        onUpgrade: () async {
          Navigator.of(ctx).pop();
          try {
            final url = await widget.api.startBillingCheckout();
            await launchUrl(Uri.parse(url),
                mode: LaunchMode.externalApplication);
            await _refreshBilling();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text('Fel: $e')));
          }
        },
      ),
    );
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2042),
        title: const Text('Logga ut?',
            style: TextStyle(color: Colors.white)),
        content: const Text('Du loggas ut från BankID-sessionen.',
            style: TextStyle(color: GlassPalette.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Avbryt')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Logga ut',
                  style: TextStyle(color: GlassPalette.danger))),
        ],
      ),
    );
    if (ok == true) {
      try {
        await widget.api.logout();
      } catch (_) {}
      widget.onLogout();
    }
  }

  @override
  Widget build(BuildContext context) {
    final newCount = _added.length;
    final totalCount = _times.length;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: GlassPalette.accentSoft,
        backgroundColor: const Color(0xFF1A2042),
        onRefresh: () async {
          await _refreshBilling();
          await _scanOnce();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 120),
          children: [
            SectionHeader(
              'Sök tider',
              subtitle: _lastScan == null
                  ? 'Tryck för att starta sökning'
                  : 'Senaste sökning: ${_fmtTime(_lastScan!)}',
              trailing: GlassChip(
                label: 'Logga ut',
                icon: Icons.logout_rounded,
                onTap: _confirmLogout,
              ),
            ),
            if (_billing != null) _BillingCard(
              billing: _billing!,
              onUpgrade: () => _showPaywall(
                  'Aktivera live-läge för att boka tider direkt från appen.'),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: GlassButton(
                    label: _scanning ? 'Söker…' : 'Sök tider nu',
                    icon: Icons.search_rounded,
                    loading: _scanning,
                    onPressed: _scanning ? null : _scanOnce,
                    expand: true,
                  ),
                ),
                const SizedBox(width: 10),
                GlassChip(
                  label: _autoScan ? 'Auto: PÅ' : 'Auto: AV',
                  selected: _autoScan,
                  icon: _autoScan
                      ? Icons.autorenew_rounded
                      : Icons.pause_circle_outline,
                  onTap: _toggleAutoScan,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              GlassPanel(
                tint: GlassPalette.danger,
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.white))),
                ]),
              ),
            ],
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: _StatTile(label: 'Tider', value: '$totalCount')),
              const SizedBox(width: 10),
              Expanded(
                  child:
                      _StatTile(label: 'Nya', value: '$newCount', highlight: true)),
              const SizedBox(width: 10),
              Expanded(
                  child: _StatTile(
                      label: 'Platser',
                      value: '${_times.map((s) => s.location).toSet().length}')),
            ]),
            if (_verifyingSlot != null) ...[
              const SizedBox(height: 18),
              _VerifyCard(slot: _verifyingSlot!, result: _verifyResult),
            ],
            if (_added.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.fromLTRB(6, 22, 6, 8),
                child: Text('Nya tider',
                    style: TextStyle(
                        color: GlassPalette.success,
                        fontWeight: FontWeight.w700,
                        fontSize: 17)),
              ),
              ..._added.map((s) =>
                  _SlotCard(slot: s, fresh: true, onBoka: _onBoka)),
            ],
            const Padding(
              padding: EdgeInsets.fromLTRB(6, 22, 6, 8),
              child: Text('Alla tider',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                      fontSize: 17)),
            ),
            if (_times.isEmpty)
              GlassPanel(
                padding: const EdgeInsets.all(28),
                child: Column(children: [
                  Icon(Icons.event_available_outlined,
                      size: 44, color: Colors.white.withOpacity(0.5)),
                  const SizedBox(height: 8),
                  const Text(
                    'Inga tider hittade ännu.',
                    style: TextStyle(color: GlassPalette.textSecondary),
                  ),
                ]),
              )
            else
              ..._times.map((s) => _SlotCard(slot: s, onBoka: _onBoka)),
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final bool highlight;
  const _StatTile(
      {required this.label, required this.value, this.highlight = false});

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 10),
      tint: highlight ? GlassPalette.success : null,
      child: Column(
        children: [
          Text(value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              )),
          const SizedBox(height: 2),
          Text(label,
              style: const TextStyle(
                color: GlassPalette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              )),
        ],
      ),
    );
  }
}

class _BillingCard extends StatelessWidget {
  final BillingStatus billing;
  final VoidCallback onUpgrade;
  const _BillingCard({required this.billing, required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final paid = billing.paid;
    return GlassPanel(
      tint: paid ? GlassPalette.success : GlassPalette.warning,
      margin: const EdgeInsets.only(top: 12),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.18),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(paid ? Icons.bolt_rounded : Icons.lock_outline_rounded,
                color: Colors.white),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(paid ? 'Live-läge aktivt' : 'Demoläge',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                Text(
                  paid
                      ? (billing.paidUntil != null
                          ? 'Förnyas ${billing.paidUntil!.split("T").first}'
                          : 'Du kan boka tider direkt.')
                      : 'Aktivera live-läge för att boka.',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12),
                ),
              ],
            ),
          ),
          if (!paid && billing.stripeEnabled)
            GlassButton(
              label: 'Aktivera',
              icon: Icons.flash_on_rounded,
              onPressed: onUpgrade,
            ),
        ],
      ),
    );
  }
}

class _SlotCard extends StatelessWidget {
  final Slot slot;
  final bool fresh;
  final ValueChanged<Slot> onBoka;
  const _SlotCard({required this.slot, this.fresh = false, required this.onBoka});

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 10),
      tint: fresh ? GlassPalette.success : null,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 56,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withOpacity(0.22),
                  Colors.white.withOpacity(0.08),
                ],
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withOpacity(0.18)),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_dayName(slot.date),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
                Text(_dayNumber(slot.date),
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w800)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${slot.time}  ·  ${slot.location}',
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 15)),
                const SizedBox(height: 2),
                Text(
                  [
                    if (slot.name.isNotEmpty) slot.name,
                    if (slot.cost.isNotEmpty) slot.cost,
                  ].join(' · '),
                  style: const TextStyle(
                      color: GlassPalette.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          GlassButton(label: 'Boka', onPressed: () => onBoka(slot)),
        ],
      ),
    );
  }

  static const _dayNames = ['mån', 'tis', 'ons', 'tor', 'fre', 'lör', 'sön'];
  String _dayName(String iso) {
    try {
      final p = iso.split('-');
      final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      return _dayNames[(d.weekday - 1) % 7];
    } catch (_) {
      return '';
    }
  }

  String _dayNumber(String iso) {
    try {
      return iso.split('-').last;
    } catch (_) {
      return '?';
    }
  }
}

class _VerifyCard extends StatelessWidget {
  final Slot slot;
  final bool? result;
  const _VerifyCard({required this.slot, required this.result});

  @override
  Widget build(BuildContext context) {
    String text;
    Color color;
    IconData icon;
    if (result == null) {
      text = 'Kontrollerar hos Trafikverket…';
      color = GlassPalette.accentSoft;
      icon = Icons.hourglass_top_rounded;
    } else if (result == true) {
      text = 'Tiden finns kvar hos Trafikverket';
      color = GlassPalette.success;
      icon = Icons.check_circle_rounded;
    } else {
      text = 'Tiden är inte längre ledig';
      color = GlassPalette.danger;
      icon = Icons.cancel_rounded;
    }
    return GlassPanel(
      tint: color,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Skickat till Trafikverket',
              style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 13)),
          const SizedBox(height: 4),
          Text('${slot.date}  ${slot.time}  –  ${slot.location}',
              style: const TextStyle(color: Colors.white, fontSize: 14)),
          const SizedBox(height: 8),
          Row(children: [
            Icon(icon, color: Colors.white, size: 18),
            const SizedBox(width: 6),
            Expanded(
                child: Text(text,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w600))),
          ]),
        ],
      ),
    );
  }
}

class _Paywall extends StatelessWidget {
  final String message;
  final BillingStatus? billing;
  final VoidCallback onUpgrade;
  const _Paywall(
      {required this.message, required this.billing, required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
          16, 0, 16, MediaQuery.of(context).viewInsets.bottom + 24),
      child: GlassPanel(
        padding: const EdgeInsets.fromLTRB(22, 22, 22, 22),
        radius: 28,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.4),
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Live-läge krävs',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Text(message,
                style: const TextStyle(color: GlassPalette.textSecondary)),
            const SizedBox(height: 18),
            GlassButton(
              label:
                  'Aktivera live${billing?.priceLabel != null && billing!.priceLabel.isNotEmpty ? ' – ${billing!.priceLabel}' : ''}',
              icon: Icons.flash_on_rounded,
              onPressed: onUpgrade,
              expand: true,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                  foregroundColor: GlassPalette.textSecondary),
              child: const Text('Avbryt'),
            ),
          ],
        ),
      ),
    );
  }
}
