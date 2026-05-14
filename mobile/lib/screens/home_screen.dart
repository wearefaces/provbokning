import 'dart:async';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../models.dart';

class HomeScreen extends StatefulWidget {
  final ApiClient api;
  final VoidCallback onLogout;

  const HomeScreen({super.key, required this.api, required this.onLogout});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  BillingStatus? _billing;
  List<Slot> _times = [];
  List<Slot> _added = [];
  bool _scanning = false;
  bool _autoScan = false;
  Timer? _scanTimer;
  String? _error;
  Slot? _verifyingSlot;
  bool? _verifyResult;

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
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message == 'not_authenticated'
            ? 'Sessionen har gått ut. Logga in igen.'
            : 'Skanningsfel: ${e.message}';
        _scanning = false;
        if (e.message == 'not_authenticated') {
          widget.onLogout();
        }
      });
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
      _scanTimer = Timer.periodic(const Duration(seconds: 30), (_) => _scanOnce());
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
      // Open Trafikverket in the OS browser so the user can finalize the booking.
      final url = _buildBookingUrl(slot);
      if (url != null) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      }
      // Verify in background.
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
    // Mirrors the SPA route used by the web client. SSN is omitted since the
    // mobile client does not yet capture it; user gets the location-filtered
    // view instead.
    final loc = s.locationId ?? 0;
    return 'https://fp.trafikverket.se/Boka/#/search///5/12/$loc/2';
  }

  Future<void> _showPaywall(String message) async {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Live-läge krävs',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text(message),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () async {
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
              child: Text(
                'Aktivera live${_billing?.priceLabel != null ? ' – ${_billing!.priceLabel}' : ''}',
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Avbryt'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Provbokning'),
        actions: [
          IconButton(
            tooltip: 'Logga ut',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await widget.api.logout();
              widget.onLogout();
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          await _refreshBilling();
          await _scanOnce();
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _BillingBanner(billing: _billing, onUpgrade: () => _showPaywall(
              'Aktivera live-läge för att kunna boka tider.',
            )),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _scanning ? null : _scanOnce,
                    icon: _scanning
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.search),
                    label: Text(_scanning ? 'Söker...' : 'Sök tider nu'),
                  ),
                ),
                const SizedBox(width: 12),
                FilterChip(
                  label: Text(_autoScan ? 'Auto: på' : 'Auto: av'),
                  selected: _autoScan,
                  onSelected: (_) => _toggleAutoScan(),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
            const SizedBox(height: 16),
            if (_verifyingSlot != null)
              _VerifyCard(slot: _verifyingSlot!, result: _verifyResult),
            const SizedBox(height: 8),
            if (_added.isNotEmpty) ...[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('Nya tider',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              ..._added.map((s) => _SlotTile(slot: s, fresh: true, onBoka: _onBoka)),
            ],
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Alla tider',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            ),
            if (_times.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Center(
                  child: Text(
                    'Inga tider hittade ännu. Tryck "Sök tider nu" för att starta.',
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else
              ..._times.map((s) => _SlotTile(slot: s, onBoka: _onBoka)),
          ],
        ),
      ),
    );
  }
}

class _BillingBanner extends StatelessWidget {
  final BillingStatus? billing;
  final VoidCallback onUpgrade;
  const _BillingBanner({required this.billing, required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    if (billing == null) return const SizedBox.shrink();
    final paid = billing!.paid;
    final color = paid ? Colors.green.shade50 : Colors.amber.shade50;
    final dot = paid ? Colors.green : Colors.amber;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dot.withOpacity(0.5)),
      ),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  paid ? 'Live-läge aktivt' : 'Demoläge',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                Text(
                  paid
                      ? 'Du kan boka tider och får automatiska notiser.'
                      : 'Aktivera live-läge för att boka tider.',
                  style: const TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          if (!paid && billing!.stripeEnabled)
            FilledButton(
              onPressed: onUpgrade,
              child: Text('Aktivera ${billing!.priceLabel}'),
            ),
        ],
      ),
    );
  }
}

class _SlotTile extends StatelessWidget {
  final Slot slot;
  final bool fresh;
  final ValueChanged<Slot> onBoka;
  const _SlotTile({required this.slot, this.fresh = false, required this.onBoka});

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: fresh ? Colors.green.shade50 : null,
      child: ListTile(
        title: Text('${slot.date} ${slot.time}',
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text('${slot.location}${slot.cost.isNotEmpty ? " • ${slot.cost}" : ""}'),
        trailing: FilledButton(
          onPressed: () => onBoka(slot),
          child: const Text('Boka'),
        ),
      ),
    );
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
    if (result == null) {
      text = 'Kontrollerar hos Trafikverket...';
      color = Colors.grey;
    } else if (result == true) {
      text = '✓ Tiden finns kvar hos Trafikverket';
      color = Colors.green;
    } else {
      text = '✗ Tiden är inte längre ledig hos Trafikverket';
      color = Colors.red;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Skickat till Trafikverket',
                style: TextStyle(
                    color: Theme.of(context).colorScheme.primary,
                    fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text('${slot.date} ${slot.time} – ${slot.location}'),
            const SizedBox(height: 6),
            Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}
