import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'package:dio/dio.dart' show DioException, DioExceptionType;
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../api.dart';
import '../local_notifications.dart';
import '../local_settings.dart';
import '../models.dart';
import '../scan_live_activity.dart';
import '../theme.dart';
import '../widgets/brand.dart';
import 'paywall_screen.dart';

class ScanScreen extends StatefulWidget {
  final ApiClient api;
  final VoidCallback onLogout;

  const ScanScreen({super.key, required this.api, required this.onLogout});

  @override
  State<ScanScreen> createState() => ScanScreenState();
}

class ScanScreenState extends State<ScanScreen> {
  /// Called by the shell when this tab becomes visible so the criteria
  /// card stays in sync with changes made on the settings screen.
  void refreshConfig() => _refreshConfig();

  BillingStatus? _billing;
  List<Slot> _times = [];
  List<Slot> _added = [];
  List<Reservation> _activeReservations = [];
  bool _scanning = false;
  bool _autoScan = false;
  Timer? _scanTimer;
  Timer? _reservationTimer;
  String? _error;
  Slot? _verifyingSlot;
  bool? _verifyResult;
  DateTime? _lastScan;
  int _scansToday = 0;
  int _intervalSeconds = 120;
  AppConfigData? _config;
  WatchStatus? _watch;

  @override
  void initState() {
    super.initState();
    _refreshBilling();
    _refreshReservations();
    _refreshConfig();
    _loadInterval();
    // The server may already be watching from a previous app session.
    _refreshWatch();
    _reservationTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadInterval() async {
    final v = await LocalSettings.getIntervalSeconds();
    if (mounted && v != _intervalSeconds) {
      setState(() => _intervalSeconds = v);
      if (_autoScan) {
        _scanTimer?.cancel();
        _scanTimer = Timer.periodic(
            Duration(seconds: _intervalSeconds), (_) => _scanOnce());
      }
    }
  }

  /// Returns true when the user has live access (paid). When billing is
  /// gated (Stripe enabled) and the user is still on demo, shows the
  /// paywall and returns false so the caller can abort.
  bool _requireLive() {
    final b = _billing;
    if (b == null) return true; // billing not yet loaded — don't block
    if (b.paid) return true;
    if (!b.stripeEnabled) return true; // self-hosted, no paywall
    _showPaywall('Aktivera live-läge för att ändra sökinställningar.');
    return false;
  }

  @override
  void dispose() {
    _scanTimer?.cancel();
    _reservationTimer?.cancel();
    ScanLiveActivity.instance.stop();
    super.dispose();
  }

  Future<void> _refreshBilling() async {
    try {
      final b = await widget.api.billingStatus();
      if (mounted) setState(() => _billing = b);
    } catch (_) {}
  }

  Future<void> _refreshReservations() async {
    try {
      final list = await widget.api.activeReservations();
      if (mounted) setState(() => _activeReservations = list);
    } catch (_) {}
  }

  Future<void> _refreshConfig() async {
    try {
      final c = await widget.api.getConfig();
      if (mounted) setState(() => _config = c);
    } catch (_) {}
  }

  Future<void> _markBooked(Reservation r) async {
    try {
      await widget.api.updateReservation(r.id, 'booked');
    } catch (_) {}
    await _refreshReservations();
  }

  Future<void> _dismissReservation(Reservation r) async {
    try {
      await widget.api.updateReservation(r.id, 'dismissed');
    } catch (_) {}
    await _refreshReservations();
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
        _scansToday += 1;
      });
      // Fire a local notification banner when this scan tick uncovered new
      // slots. Works whenever the Flutter timer ticks (foreground or while
      // iOS keeps the background timer alive).
      if (r.added.isNotEmpty) {
        // ignore: discarded_futures
        LocalNotifier.instance.notifyFound(r.added);
      }
      if (_autoScan) {
        ScanLiveActivity.instance.update(scanning: true, times: _times);
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message == 'not_authenticated'
            ? 'Sessionen har gått ut. Logga in igen.'
            : 'Skanningsfel: ${e.message}';
        _scanning = false;
      });
      if (e.message == 'not_authenticated') widget.onLogout();
    } on DioException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _friendlyDioError(e);
        _scanning = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Nätverksfel. Försök igen om en stund.';
        _scanning = false;
      });
    }
  }

  String _friendlyDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return 'Sökningen tog för lång tid. Trafikverket svarar långsamt — försök igen.';
      case DioExceptionType.connectionError:
        return 'Ingen anslutning till servern. Kontrollera nätverket.';
      case DioExceptionType.badCertificate:
        return 'Säkerhetsfel vid anslutning till servern.';
      case DioExceptionType.cancel:
        return 'Sökningen avbröts.';
      case DioExceptionType.badResponse:
      case DioExceptionType.unknown:
        return 'Nätverksfel. Försök igen om en stund.';
    }
  }

  Future<void> _toggleAutoScan() async {
    if (!_autoScan && !_requireLive()) return;
    setState(() => _autoScan = !_autoScan);
    if (_autoScan) {
      // Ask for notification permission lazily — only if the user hasn't
      // already granted it. iOS would otherwise silently no-op, but we
      // skip the call entirely to avoid any extra system chatter.
      // ignore: discarded_futures
      LocalNotifier.instance.ensurePermission();
      // Live Activity is a best-effort lock-screen indicator. If iOS refuses
      // (denied, unsupportedTarget, low-power mode, etc.) we silently swallow
      // the failure — the scan loop must keep running regardless.
      // ignore: discarded_futures
      ScanLiveActivity.instance.start().catchError((_) => false);
      // Hand the search to the server. This is what keeps it running when the
      // app is closed and the phone is locked — the Dart timer below only
      // keeps the visible list fresh while the app is actually open.
      await _setServerWatch(true);
      _scanOnce();
      _scanTimer = Timer.periodic(
          Duration(seconds: _intervalSeconds), (_) => _scanOnce());
    } else {
      _scanTimer?.cancel();
      await _setServerWatch(false);
      // ignore: discarded_futures
      ScanLiveActivity.instance.stop();
    }
  }

  /// Enable/disable the server-side search. Failures are surfaced but never
  /// block the in-app timer, so the app still works if the server is older.
  Future<void> _setServerWatch(bool enabled) async {
    try {
      final w = await widget.api
          .setWatch(enabled: enabled, intervalSeconds: _intervalSeconds);
      if (!mounted) return;
      setState(() => _watch = w);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message == 'not_authenticated'
          ? 'Sessionen har gått ut. Logga in igen.'
          : 'Kunde inte starta bevakning på servern: ${e.message}');
      if (e.message == 'not_authenticated') widget.onLogout();
    } catch (_) {
      if (!mounted) return;
      setState(() => _error =
          'Bevakningen kunde inte startas på servern. Sökningen körs bara '
          'medan appen är öppen.');
    }
  }

  Future<void> _refreshWatch() async {
    try {
      final w = await widget.api.watchStatus();
      if (!mounted) return;
      setState(() {
        _watch = w;
        // The server is the source of truth: if it is already watching (e.g.
        // the app was killed and reopened), show auto-search as on and resume
        // the foreground refresh timer.
        if (w.active && !_autoScan) {
          _autoScan = true;
          _scanTimer?.cancel();
          _scanTimer = Timer.periodic(
              Duration(seconds: _intervalSeconds), (_) => _scanOnce());
        }
      });
    } catch (_) {}
  }

  Future<void> _openSlotDetail(Slot slot) async {
    final confirm = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.65),
      builder: (_) => _SlotDetailSheet(slot: slot, examType: _config?.examType),
    );
    if (confirm == true) {
      await _onBoka(slot);
    }
  }

  Future<void> _onBoka(Slot slot) async {
    setState(() {
      _verifyingSlot = slot;
      _verifyResult = null;
    });

    // Open Trafikverket's booking page first so the user always lands on
    // the correct slot, even if our reserve/verify backend call fails.
    final url = _buildBookingUrl(slot);
    if (url != null) {
      try {
        await launchUrl(Uri.parse(url),
            mode: LaunchMode.externalApplication);
      } catch (_) {/* fall through — still try to reserve below */}
    }

    try {
      await widget.api.reserve(slot);
      await _refreshReservations();
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
    // Map licence to Trafikverket's numeric IDs (mirrors api.py).
    const licences = <String, int>{
      'B': 5,
      'A': 4,
      'A1': 2,
      'A2': 24,
    };

    // Prefer the user's configured licence; fall back to slot.name parsing
    // ("B - Körprov") and finally to B as default.
    String licenceCode = (_config?.licenceType ?? 'B').toUpperCase();
    final n = s.name.toLowerCase();
    if (n.startsWith('a2')) licenceCode = 'A2';
    else if (n.startsWith('a1')) licenceCode = 'A1';
    else if (n.startsWith('a')) licenceCode = 'A';
    else if (n.startsWith('b')) licenceCode = 'B';

    final licenceId = licences[licenceCode] ?? 5;

    // Trafikverket booking SPA route:
    //   /Boka/ng/search/<sessionSeed>/<licence>/0/0/0
    // The session seed is an opaque token (any 12–16 letter string works).
    // We only pass licence — passing exam/location/vehicle in the path makes
    // the SPA bounce back to "Välkommen" / "Mina sidor". The user lands on the
    // licence-specific search wizard and picks the slot from the list.
    final token = _randomSearchToken();
    return 'https://fp.trafikverket.se/Boka/ng/search/$token/$licenceId/0/0/0';
  }

  String _randomSearchToken() {
    const chars =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
    final rnd = math.Random();
    return List.generate(14, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _showPaywall(String message) async {
    final ok = await IapPaywall.show(
      context,
      api: widget.api,
      message: message,
    );
    if (ok == true) {
      await _refreshBilling();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: BrandPalette.ink,
          content: Text('Provbok Pro aktiverat!',
              style: TextStyle(color: Colors.white)),
        ),
      );
    }
  }

  Future<void> _confirmLogout() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 28),
        child: BrandCard(
          color: BrandPalette.ink,
          radius: 26,
          padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: BrandPalette.lime,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Icon(Icons.logout_rounded,
                      color: BrandPalette.ink, size: 22),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text('Logga ut?',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      )),
                ),
              ]),
              const SizedBox(height: 14),
              Text(
                'Du loggas ut från BankID-sessionen och behöver autentisera dig igen för att fortsätta söka tider.',
                style: TextStyle(
                  color: Colors.white.withOpacity(0.78),
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              BrandCTA(
                label: 'Logga ut',
                icon: Icons.logout_rounded,
                onPressed: () => Navigator.pop(ctx, true),
              ),
              const SizedBox(height: 10),
              BrandCTA(
                label: 'Avbryt',
                variant: BrandCTAVariant.secondaryOnDark,
                onPressed: () => Navigator.pop(ctx, false),
              ),
            ],
          ),
        ),
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
    final places = _times.map((s) => s.location).toSet().length;
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: BrandPalette.ink,
        backgroundColor: BrandPalette.surface,
        onRefresh: () async {
          await _refreshBilling();
          await _refreshReservations();
          await _scanOnce();
        },
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 140),
          children: [
            // ── BRAND HEADER ──────────────────────────────────────
            _BrandHeaderRow(
              paid: _billing?.paid ?? false,
              onModeTap: (_billing?.paid ?? false)
                  ? null
                  : () => _showPaywall(
                      'Aktivera live-läge för att boka tider direkt från appen.'),
              onLogout: _confirmLogout,
            ),
            const SizedBox(height: 14),

            // ── AUTO-SÖK HERO ─────────────────────────────────────
            _AutoSokHero(
              enabled: _autoScan,
              scanning: _scanning,
              scansToday: _scansToday,
              intervalSeconds: _intervalSeconds,
              onToggle: _toggleAutoScan,
              onIntervalTap: () => _pickInterval(),
              serverWatching: _watch?.active ?? false,
            ),
            const SizedBox(height: 12),

            // ── MANUAL SCAN CTA ───────────────────────────────────
            BrandCTA(
              label: (_scanning) ? 'Söker…' : 'Sök tider nu',
              icon: _scanning
                  ? Icons.hourglass_top_rounded
                  : Icons.search_rounded,
              onPressed: _scanning ? null : _scanOnce,
              loading: _scanning,
            ),

            // ── DINA SÖKKRITERIER ──────────────────────────────────
            if (_config != null) ...[
              const SizedBox(height: 14),
              _SearchCriteriaCard(
                config: _config!,
                onEdit: _openFilters,
              ),
            ],

            // ── BILLING ────────────────────────────────────────────
            if (_billing != null) ...[
              const SizedBox(height: 14),
              _BillingCard(
                billing: _billing!,
                onUpgrade: () => _showPaywall(
                    'Aktivera live-läge för att boka tider direkt från appen.'),
              ),
            ],

            // ── ACTIVE RESERVATIONS ───────────────────────────────
            if (_activeReservations.isNotEmpty) ...[
              const SizedBox(height: 14),
              _ActiveBookingsCard(
                reservations: _activeReservations,
                onBooked: _markBooked,
                onDismiss: _dismissReservation,
                onOpen: (r) async {
                  final url = _buildBookingUrl(r.slot);
                  if (url != null) {
                    await launchUrl(Uri.parse(url),
                        mode: LaunchMode.externalApplication);
                  }
                },
              ),
            ],

            // ── ERROR ──────────────────────────────────────────────
            if (_error != null) ...[
              const SizedBox(height: 14),
              BrandCard(
                color: BrandPalette.danger,
                padding: const EdgeInsets.all(14),
                child: Row(children: [
                  const Icon(Icons.error_outline, color: Colors.white),
                  const SizedBox(width: 10),
                  Expanded(
                      child: Text(_error!,
                          style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600))),
                ]),
              ),
            ],

            // ── STATS ──────────────────────────────────────────────
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                  child: BrandStat(
                      value: '$totalCount',
                      label: 'Tider',
                      icon: Icons.event_available_rounded)),
              const SizedBox(width: 10),
              Expanded(
                  child: BrandStat(
                      value: '$newCount',
                      label: 'Nya',
                      icon: Icons.fiber_new_rounded,
                      valueColor: BrandPalette.success)),
              const SizedBox(width: 10),
              Expanded(
                  child: BrandStat(
                      value: '$places',
                      label: 'Platser',
                      icon: Icons.place_outlined)),
            ]),

            // ── VERIFY ─────────────────────────────────────────────
            if (_verifyingSlot != null) ...[
              const SizedBox(height: 16),
              _VerifyCard(slot: _verifyingSlot!, result: _verifyResult),
            ],

            // ── NEW SLOTS ──────────────────────────────────────────
            if (_added.isNotEmpty) ...[
              const SizedBox(height: 22),
              _LedigaTiderHeader(title: 'Nya tider', count: _added.length),
              const SizedBox(height: 10),
              BrandCard(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    for (int i = 0; i < _added.length; i++) ...[
                      _SlotRow(
                          slot: _added[i], fresh: true, onTap: _openSlotDetail),
                      if (i != _added.length - 1) const _RowDivider(),
                    ],
                  ],
                ),
              ),
            ],

            // ── ALL SLOTS ──────────────────────────────────────────
            const SizedBox(height: 22),
            _LedigaTiderHeader(
              title: 'Lediga tider',
              count: _times.length,
              trailing: _autoScan ? 'Auto-sök på' : null,
            ),
            const SizedBox(height: 10),
            if (_times.isEmpty)
              BrandCard(
                padding: const EdgeInsets.all(28),
                child: Column(children: const [
                  Icon(Icons.event_available_outlined,
                      size: 44, color: BrandPalette.textMuted),
                  SizedBox(height: 8),
                  Text('Inga tider hittade ännu.',
                      style: TextStyle(color: BrandPalette.textSecondary)),
                ]),
              )
            else
              BrandCard(
                padding: const EdgeInsets.all(8),
                child: Column(
                  children: [
                    for (int i = 0; i < _times.length; i++) ...[
                      _SlotRow(slot: _times[i], onTap: _openSlotDetail),
                      if (i != _times.length - 1) const _RowDivider(),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 14),
            Center(
              child: Text(
                _autoScan
                    ? 'Fler tider laddas automatiskt…'
                    : 'Fler tider kan bli tillgängliga – vi bevakar dygnet runt.',
                style: const TextStyle(
                    color: BrandPalette.textSecondary, fontSize: 12.5),
              ),
            ),
            if (!_autoScan) ...[
              const SizedBox(height: 10),
              Center(
                child: TextButton.icon(
                  onPressed: _toggleAutoScan,
                  icon: const Icon(Icons.autorenew_rounded,
                      color: BrandPalette.lime, size: 18),
                  label: const Text('Aktivera auto-sök',
                      style: TextStyle(
                          color: BrandPalette.lime,
                          fontWeight: FontWeight.w700)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  Future<void> _pickInterval() async {
    if (!_requireLive()) return;
    final choice = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: BrandPalette.ink,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text('Sökintervall',
                  style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 18)),
            ),
            for (final s in const [30, 60, 120, 300, 600])
              ListTile(
                title: Text(_intervalLabel(s),
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600)),
                trailing: s == _intervalSeconds
                    ? const Icon(Icons.check_rounded,
                        color: BrandPalette.lime)
                    : null,
                onTap: () => Navigator.pop(ctx, s),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (choice != null && choice != _intervalSeconds) {
      setState(() => _intervalSeconds = choice);
      // ignore: discarded_futures
      LocalSettings.setIntervalSeconds(choice);
      if (_autoScan) {
        _scanTimer?.cancel();
        _scanTimer = Timer.periodic(
            Duration(seconds: _intervalSeconds), (_) => _scanOnce());
        // Keep the server-side search on the same interval.
        // ignore: discarded_futures
        _setServerWatch(true);
      }
    }
  }

  static String _intervalLabel(int s) {
    if (s < 60) return 'Var $s:e sekund';
    if (s == 60) return 'Var minut';
    if (s < 3600) return 'Var ${s ~/ 60}:a minut';
    return 'Var ${s ~/ 3600}:e timme';
  }

  Future<void> _openFilters() async {
    if (!_requireLive()) return;
    if (_config == null) return;
    final updated = await showModalBottomSheet<AppConfigData>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => _FilterSheet(
        api: widget.api,
        initial: _config!,
      ),
    );
    if (updated != null) {
      setState(() => _config = updated);
      try {
        await widget.api.saveConfig(updated.toJson());
      } catch (_) {}
      // Re-scan with new filters.
      _scanOnce();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Billing card
// ─────────────────────────────────────────────────────────────────────────────
class _BillingCard extends StatelessWidget {
  final BillingStatus billing;
  final VoidCallback onUpgrade;
  const _BillingCard({required this.billing, required this.onUpgrade});

  @override
  Widget build(BuildContext context) {
    final paid = billing.paid;
    return BrandCard(
      color: paid ? BrandPalette.lime : BrandPalette.surface,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: paid
                  ? BrandPalette.ink
                  : BrandPalette.warning.withOpacity(0.2),
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(
              paid ? Icons.bolt_rounded : Icons.lock_outline_rounded,
              color: paid ? BrandPalette.lime : BrandPalette.warning,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(paid ? 'Live-läge aktivt' : 'Demoläge',
                    style: TextStyle(
                        color: paid
                            ? BrandPalette.ink
                            : BrandPalette.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 15.5,
                        letterSpacing: -0.2)),
                const SizedBox(height: 2),
                Text(
                  paid
                      ? (billing.paidUntil != null
                          ? 'Förnyas ${billing.paidUntil!.split("T").first}'
                          : 'Du kan boka tider direkt.')
                      : 'Aktivera live-läge för att boka.',
                  style: TextStyle(
                      color: paid
                          ? BrandPalette.ink.withOpacity(0.7)
                          : BrandPalette.textSecondary,
                      fontSize: 12.5),
                ),
              ],
            ),
          ),
          if (!paid && billing.stripeEnabled)
            BrandPill(
              label: 'Aktivera',
              icon: Icons.flash_on_rounded,
              onPressed: onUpgrade,
              dense: true,
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Slot card
// ─────────────────────────────────────────────────────────────────────────────
class _SlotCard extends StatelessWidget {
  final Slot slot;
  final bool fresh;
  final ValueChanged<Slot> onBoka;
  const _SlotCard(
      {required this.slot, this.fresh = false, required this.onBoka});

  @override
  Widget build(BuildContext context) {
    return BrandCard(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          // Date pill
          Container(
            width: 56,
            height: 64,
            decoration: BoxDecoration(
              color: fresh ? BrandPalette.lime : BrandPalette.surfaceMuted,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_dayName(slot.date),
                    style: const TextStyle(
                        color: BrandPalette.ink,
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6)),
                const SizedBox(height: 2),
                Text(_dayNumber(slot.date),
                    style: const TextStyle(
                        color: BrandPalette.ink,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6)),
              ],
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${slot.time}  ·  ${slot.location}',
                    style: const TextStyle(
                        color: BrandPalette.textPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        letterSpacing: -0.2)),
                const SizedBox(height: 3),
                Text(
                  [
                    if (slot.name.isNotEmpty) slot.name,
                    if (slot.cost.isNotEmpty) slot.cost,
                  ].join(' · '),
                  style: const TextStyle(
                      color: BrandPalette.textSecondary, fontSize: 12.5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          BrandPill(
            label: 'Boka',
            onPressed: () => onBoka(slot),
            dense: true,
          ),
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

// ─────────────────────────────────────────────────────────────────────────────
// Verify card
// ─────────────────────────────────────────────────────────────────────────────
class _VerifyCard extends StatelessWidget {
  final Slot slot;
  final bool? result;
  const _VerifyCard({required this.slot, required this.result});

  @override
  Widget build(BuildContext context) {
    String text;
    Color bg;
    Color fg;
    IconData icon;
    if (result == null) {
      text = 'Kontrollerar hos Trafikverket…';
      bg = BrandPalette.surfaceMuted;
      fg = BrandPalette.ink;
      icon = Icons.hourglass_top_rounded;
    } else if (result == true) {
      text = 'Tiden finns kvar hos Trafikverket';
      bg = BrandPalette.lime;
      fg = BrandPalette.ink;
      icon = Icons.check_circle_rounded;
    } else {
      text = 'Tiden är inte längre ledig';
      bg = BrandPalette.danger;
      fg = Colors.white;
      icon = Icons.cancel_rounded;
    }
    return BrandCard(
      color: bg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('SKICKAT TILL TRAFIKVERKET',
              style: TextStyle(
                  color: fg.withOpacity(0.7),
                  fontWeight: FontWeight.w800,
                  fontSize: 11,
                  letterSpacing: 1.4)),
          const SizedBox(height: 6),
          Text('${slot.date}  ${slot.time}  –  ${slot.location}',
              style: TextStyle(
                  color: fg,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 10),
          Row(children: [
            Icon(icon, color: fg, size: 18),
            const SizedBox(width: 6),
            Expanded(
                child: Text(text,
                    style: TextStyle(
                        color: fg, fontWeight: FontWeight.w600))),
          ]),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Active bookings card
// ─────────────────────────────────────────────────────────────────────────────
class _ActiveBookingsCard extends StatelessWidget {
  final List<Reservation> reservations;
  final ValueChanged<Reservation> onBooked;
  final ValueChanged<Reservation> onDismiss;
  final ValueChanged<Reservation> onOpen;
  const _ActiveBookingsCard({
    required this.reservations,
    required this.onBooked,
    required this.onDismiss,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    return BrandCard(
      color: BrandPalette.ink,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: BrandPalette.lime,
                borderRadius: BorderRadius.circular(11),
              ),
              child: const Icon(Icons.bookmark_rounded,
                  color: BrandPalette.ink, size: 20),
            ),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                'Aktiva bokningar',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: BrandPalette.lime,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                '${reservations.length}',
                style: const TextStyle(
                  color: BrandPalette.ink,
                  fontWeight: FontWeight.w800,
                  fontSize: 13,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          Text(
            'Hålltid 15 minuter – slutför bokningen hos Trafikverket innan tiden går ut.',
            style: TextStyle(
                color: Colors.white.withOpacity(0.7), fontSize: 12.5),
          ),
          const SizedBox(height: 14),
          for (final r in reservations) ...[
            _ReservationRow(
              reservation: r,
              onBooked: () => onBooked(r),
              onDismiss: () => onDismiss(r),
              onOpen: () => onOpen(r),
            ),
            if (r != reservations.last)
              Divider(color: Colors.white.withOpacity(0.12), height: 22),
          ],
        ],
      ),
    );
  }
}

class _ReservationRow extends StatelessWidget {
  final Reservation reservation;
  final VoidCallback onBooked;
  final VoidCallback onDismiss;
  final VoidCallback onOpen;
  const _ReservationRow({
    required this.reservation,
    required this.onBooked,
    required this.onDismiss,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final s = reservation.slot;
    final mins = reservation.minutesLeft();
    final expiring = mins <= 3;
    final timeLabel = mins <= 0
        ? 'Utgången'
        : (mins < 60
            ? '${mins} min kvar'
            : '${(mins / 60).floor()} h ${mins % 60} min kvar');

    final timeColor = expiring ? BrandPalette.danger : BrandPalette.lime;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${s.date}  ${s.time}',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
            fontSize: 17,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          [
            if (s.location.isNotEmpty) s.location,
            if (s.name.isNotEmpty) s.name,
            if (s.cost.isNotEmpty) s.cost,
          ].join(' · '),
          style: TextStyle(
              color: Colors.white.withOpacity(0.7), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.timer_outlined, size: 14, color: timeColor),
          const SizedBox(width: 6),
          Text(
            timeLabel,
            style: TextStyle(
              color: timeColor,
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              letterSpacing: 0.2,
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: BrandPill(
              label: 'Öppna Trafikverket',
              icon: Icons.open_in_new_rounded,
              onPressed: onOpen,
              expand: true,
              dense: true,
            ),
          ),
          const SizedBox(width: 8),
          _DarkChip(
              label: 'Bokad', icon: Icons.check_rounded, onTap: onBooked),
          const SizedBox(width: 6),
          _DarkChip(
              label: 'Stäng', icon: Icons.close_rounded, onTap: onDismiss),
        ]),
      ],
    );
  }
}

class _DarkChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const _DarkChip(
      {required this.label, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withOpacity(0.10),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, color: Colors.white, size: 14),
            const SizedBox(width: 6),
            Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5)),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auto-scan toggle tile — full-width row with description, status pill and
// a real Switch on the right. When the toggle is ON, the border becomes a
// continuously rotating lime gradient ("marching ants" / spinning halo) to
// signal that the background scan loop is alive.
// ─────────────────────────────────────────────────────────────────────────────
class _AutoScanTile extends StatefulWidget {
  final bool enabled;
  final VoidCallback onToggle;
  const _AutoScanTile({required this.enabled, required this.onToggle});

  @override
  State<_AutoScanTile> createState() => _AutoScanTileState();
}

class _AutoScanTileState extends State<_AutoScanTile>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _AutoScanTile old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.enabled && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final accent = enabled ? BrandPalette.lime : BrandPalette.surfaceMuted;
    final iconColor = enabled ? BrandPalette.ink : BrandPalette.textSecondary;
    const radius = 20.0;

    final content = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(radius),
      child: InkWell(
        borderRadius: BorderRadius.circular(radius),
        onTap: widget.onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  enabled
                      ? Icons.autorenew_rounded
                      : Icons.pause_circle_outline,
                  color: iconColor,
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Automatisk sökning',
                      style: TextStyle(
                        color: BrandPalette.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'Söker var 30:e sekund i bakgrunden',
                      style: TextStyle(
                        color: BrandPalette.textSecondary,
                        fontSize: 12.5,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: enabled,
                onChanged: (_) => widget.onToggle(),
                activeColor: BrandPalette.ink,
                activeTrackColor: BrandPalette.lime,
              ),
            ],
          ),
        ),
      ),
    );

    if (!enabled) {
      return Container(
        decoration: BoxDecoration(
          color: BrandPalette.surfaceMuted,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: BrandPalette.stroke.withOpacity(0.6),
            width: 1.4,
          ),
        ),
        child: content,
      );
    }

    // Active state: paint the rotating gradient border via a CustomPainter.
    // `foregroundPainter` is critical here — a regular `painter` paints
    // BEHIND the child, and the child's solid `surfaceMuted` fill would
    // hide the stroked border entirely (which is what the user reported:
    // only the icon animated). The foreground painter draws the halo on
    // top of the child so the rotating edge is always visible.
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        return CustomPaint(
          foregroundPainter: _RotatingBorderPainter(
            t: _ctrl.value,
            radius: radius,
            strokeWidth: 2.2,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: BrandPalette.surfaceMuted,
              borderRadius: BorderRadius.circular(radius),
            ),
            child: child,
          ),
        );
      },
      child: content,
    );
  }
}

class _RotatingBorderPainter extends CustomPainter {
  final double t; // 0..1
  final double radius;
  final double strokeWidth;
  _RotatingBorderPainter({
    required this.t,
    required this.radius,
    required this.strokeWidth,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(radius),
    );
    // SweepGradient rotated by `t` — gives a halo that spins around the tile.
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: 2 * 3.1415926535,
      transform: GradientRotation(2 * 3.1415926535 * t),
      colors: const [
        BrandPalette.lime,
        Color(0x00C7E84A), // transparent lime
        BrandPalette.lime,
        Color(0x00C7E84A),
        BrandPalette.lime,
      ],
      stops: const [0.0, 0.25, 0.5, 0.75, 1.0],
    ).createShader(rect);

    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(covariant _RotatingBorderPainter old) =>
      old.t != t || old.radius != radius || old.strokeWidth != strokeWidth;
}

// ─────────────────────────────────────────────────────────────────────────────
// Scan-active banner — pulsing visual indicator while a scan is in progress.
// ─────────────────────────────────────────────────────────────────────────────
class _ScanActiveBanner extends StatefulWidget {
  final bool scanning;
  final int locations;
  const _ScanActiveBanner(
      {required this.scanning, required this.locations});

  @override
  State<_ScanActiveBanner> createState() => _ScanActiveBannerState();
}

class _ScanActiveBannerState extends State<_ScanActiveBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(seconds: 1))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = widget.scanning ? 'Söker hos Trafikverket…' : 'Auto-scan aktiv';
    final sub = widget.scanning
        ? 'Hämtar lediga tider just nu'
        : 'Sökning körs var 30:e sekund';
    return BrandCard(
      color: BrandPalette.ink,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(children: [
        FadeTransition(
          opacity: Tween<double>(begin: 0.35, end: 1.0).animate(_ctrl),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: BrandPalette.lime,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: BrandPalette.lime.withOpacity(0.55),
                  blurRadius: 18,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: const Icon(Icons.radar_rounded,
                color: BrandPalette.ink, size: 22),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w800,
                    fontSize: 14.5,
                    letterSpacing: -0.2,
                  )),
              const SizedBox(height: 2),
              Text(sub,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 12.5,
                  )),
            ],
          ),
        ),
        if (widget.scanning)
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2.4,
              valueColor: AlwaysStoppedAnimation(BrandPalette.lime),
            ),
          ),
      ]),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Small status badge shown beside the logout button indicating Live/Demo mode.
// ─────────────────────────────────────────────────────────────────────────────
class _ModeBadge extends StatelessWidget {
  final bool paid;
  final VoidCallback? onTap;
  const _ModeBadge({required this.paid, this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = paid ? BrandPalette.lime : BrandPalette.surfaceMuted;
    final fg = paid ? BrandPalette.ink : BrandPalette.textSecondary;
    final icon = paid ? Icons.bolt_rounded : Icons.lock_outline_rounded;
    final label = paid ? 'LIVE' : 'DEMO';
    final pill = Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: paid
            ? null
            : Border.all(color: BrandPalette.stroke, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: fg),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                color: fg,
                fontWeight: FontWeight.w800,
                fontSize: 11,
                letterSpacing: 0.6,
              )),
        ],
      ),
    );
    if (onTap == null) return pill;
    return GestureDetector(onTap: onTap, child: pill);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Brand header — "BokaProv" wordmark + LIVE/DEMO pill + small logout button.
// ─────────────────────────────────────────────────────────────────────────────
class _BrandHeaderRow extends StatelessWidget {
  final bool paid;
  final VoidCallback? onModeTap;
  final VoidCallback onLogout;
  const _BrandHeaderRow({
    required this.paid,
    required this.onModeTap,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        children: [
          RichText(
            text: const TextSpan(
              children: [
                TextSpan(
                  text: 'Boka',
                  style: TextStyle(
                    color: BrandPalette.lime,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    letterSpacing: -0.4,
                  ),
                ),
                TextSpan(
                  text: 'Prov',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    letterSpacing: -0.4,
                  ),
                ),
              ],
            ),
          ),
          const Spacer(),
          _LivePill(paid: paid, onTap: onModeTap),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: onLogout,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: BrandPalette.surfaceMuted,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(
                    color: BrandPalette.stroke.withOpacity(0.6), width: 1),
              ),
              child: const Icon(Icons.logout_rounded,
                  color: BrandPalette.textSecondary, size: 16),
            ),
          ),
        ],
      ),
    );
  }
}

class _LivePill extends StatelessWidget {
  final bool paid;
  final VoidCallback? onTap;
  const _LivePill({required this.paid, this.onTap});

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: paid ? BrandPalette.lime : BrandPalette.stroke,
          width: 1.4,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            paid ? Icons.sensors_rounded : Icons.lock_outline_rounded,
            size: 13,
            color: paid ? BrandPalette.lime : BrandPalette.textSecondary,
          ),
          const SizedBox(width: 5),
          Text(
            paid ? 'LIVE' : 'DEMO',
            style: TextStyle(
              color: paid ? BrandPalette.lime : BrandPalette.textSecondary,
              fontWeight: FontWeight.w900,
              fontSize: 11,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return GestureDetector(onTap: onTap, child: pill);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Auto-sök hero card — glowing lime border, big magnifier in a ring, switch,
// and a footer divider with "Var X" + "N sökningar idag".
// ─────────────────────────────────────────────────────────────────────────────
class _AutoSokHero extends StatefulWidget {
  final bool enabled;
  final bool scanning;
  final int scansToday;
  final int intervalSeconds;
  final VoidCallback onToggle;
  final VoidCallback onIntervalTap;

  /// True when the SERVER is running the search. That is what makes auto-search
  /// survive the app being closed and the phone locked, so it is worth saying
  /// out loud — the in-app timer alone stops as soon as iOS suspends the app.
  final bool serverWatching;

  const _AutoSokHero({
    required this.enabled,
    required this.scanning,
    required this.scansToday,
    required this.intervalSeconds,
    required this.onToggle,
    required this.onIntervalTap,
    this.serverWatching = false,
  });

  @override
  State<_AutoSokHero> createState() => _AutoSokHeroState();
}

class _AutoSokHeroState extends State<_AutoSokHero>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 3),
  );

  @override
  void initState() {
    super.initState();
    if (widget.enabled) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant _AutoSokHero old) {
    super.didUpdateWidget(old);
    if (widget.enabled && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.enabled && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    const radius = 22.0;
    final card = Container(
      decoration: BoxDecoration(
        color: BrandPalette.surface,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: enabled
            ? [
                BoxShadow(
                  color: BrandPalette.lime.withOpacity(0.35),
                  blurRadius: 38,
                  spreadRadius: -4,
                ),
              ]
            : [],
      ),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      child: Column(
        children: [
          Row(
            children: [
              // Big magnifier in a lime ring.
              SizedBox(
                width: 64,
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: enabled
                              ? BrandPalette.lime
                              : BrandPalette.stroke,
                          width: 2.2,
                        ),
                        boxShadow: enabled
                            ? [
                                BoxShadow(
                                  color:
                                      BrandPalette.lime.withOpacity(0.55),
                                  blurRadius: 22,
                                  spreadRadius: -2,
                                ),
                              ]
                            : [],
                      ),
                    ),
                    Icon(
                      Icons.search_rounded,
                      size: 30,
                      color: enabled
                          ? BrandPalette.lime
                          : BrandPalette.textMuted,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      enabled ? 'Auto-sök aktivt' : 'Auto-sök',
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 17,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      !enabled
                          ? 'Slå på för att bevaka Trafikverket\nautomatiskt i bakgrunden.'
                          : widget.serverWatching
                              ? 'Servern söker åt dig – även när\nappen är stängd och mobilen låst.'
                              : 'Söker medan appen är öppen.\nServerbevakning är inte aktiv.',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.72),
                        fontSize: 12.8,
                        height: 1.25,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch.adaptive(
                value: enabled,
                onChanged: (_) => widget.onToggle(),
                activeColor: BrandPalette.ink,
                activeTrackColor: BrandPalette.lime,
              ),
            ],
          ),
          const SizedBox(height: 14),
          Container(height: 1, color: Colors.white.withOpacity(0.06)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _HeroStatCell(
                  icon: Icons.schedule_rounded,
                  label: ScanScreenState._intervalLabel(widget.intervalSeconds),
                  trailing: Icons.keyboard_arrow_down_rounded,
                  onTap: enabled ? widget.onIntervalTap : null,
                ),
              ),
              Container(
                  width: 1, height: 22, color: Colors.white.withOpacity(0.06)),
              Expanded(
                child: _HeroStatCell(
                  icon: Icons.timeline_rounded,
                  label: '${widget.scansToday} sökningar idag',
                ),
              ),
            ],
          ),
        ],
      ),
    );

    if (!enabled) return card;

    // Animated halo border while auto-sök is active.
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) => CustomPaint(
        foregroundPainter: _RotatingBorderPainter(
          t: _ctrl.value,
          radius: radius,
          strokeWidth: 2.0,
        ),
        child: child,
      ),
      child: card,
    );
  }
}

class _HeroStatCell extends StatelessWidget {
  final IconData icon;
  final String label;
  final IconData? trailing;
  final VoidCallback? onTap;
  const _HeroStatCell({
    required this.icon,
    required this.label,
    this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          Icon(icon, size: 16, color: BrandPalette.lime),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          if (trailing != null)
            Icon(trailing, size: 16, color: Colors.white.withOpacity(0.6)),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: row,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Section header — "Lediga tider · N st" with optional trailing tag.
// ─────────────────────────────────────────────────────────────────────────────
class _LedigaTiderHeader extends StatelessWidget {
  final String title;
  final int count;
  final String? trailing;
  const _LedigaTiderHeader({
    required this.title,
    required this.count,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Row(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              fontSize: 17,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: BrandPalette.lime,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$count st',
            style: TextStyle(
              color: Colors.white.withOpacity(0.65),
              fontWeight: FontWeight.w700,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          if (trailing != null)
            Text(
              trailing!,
              style: const TextStyle(
                color: BrandPalette.lime,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
                letterSpacing: 0.2,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Compact slot row — date+day on left, time middle, location right, status
// dot + chevron. Mirrors the generated screenshot exactly while remaining
// fully interactive (tap → _onBoka flow).
// ─────────────────────────────────────────────────────────────────────────────
class _SlotRow extends StatelessWidget {
  final Slot slot;
  final bool fresh;
  final ValueChanged<Slot> onTap;
  const _SlotRow({required this.slot, this.fresh = false, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => onTap(slot),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        child: Row(
          children: [
            SizedBox(
              width: 96,
              child: Text(
                _formatDate(slot.date),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            SizedBox(
              width: 56,
              child: Text(
                slot.time,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
            ),
            Expanded(
              child: Text(
                _shortLocation(slot.location),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withOpacity(0.78),
                  fontSize: 13.5,
                ),
              ),
            ),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: fresh
                    ? BrandPalette.lime
                    : BrandPalette.success,
                boxShadow: [
                  BoxShadow(
                    color: (fresh ? BrandPalette.lime : BrandPalette.success)
                        .withOpacity(0.45),
                    blurRadius: 8,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withOpacity(0.45), size: 20),
          ],
        ),
      ),
    );
  }

  static const _dayNames = ['mån', 'tis', 'ons', 'tor', 'fre', 'lör', 'sön'];
  static const _monthNames = [
    'jan', 'feb', 'mar', 'apr', 'maj', 'jun',
    'jul', 'aug', 'sep', 'okt', 'nov', 'dec',
  ];

  String _formatDate(String iso) {
    try {
      final p = iso.split('-');
      final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      final day = _dayNames[(d.weekday - 1) % 7];
      final month = _monthNames[d.month - 1];
      return '${d.day} $month, $day';
    } catch (_) {
      return iso;
    }
  }

  String _shortLocation(String full) {
    // "Stockholm · Farsta" → "Farsta" for compact rows.
    final parts = full.split('·');
    if (parts.length >= 2) return parts.last.trim();
    return full;
  }
}

class _RowDivider extends StatelessWidget {
  const _RowDivider();
  @override
  Widget build(BuildContext context) =>
      Container(height: 1, color: Colors.white.withOpacity(0.05));
}

// ─────────────────────────────────────────────────────────────────────────────
// "Dina sökkriterier" — summary card on the main screen showing what's
// currently being scanned for, with an "Ändra" link that opens the filter
// sheet. Maps the user's AppConfigData (locations, licence, exam, dates) to
// pill-style outlined chips that mirror the generated screenshot.
// ─────────────────────────────────────────────────────────────────────────────
class _SearchCriteriaCard extends StatelessWidget {
  final AppConfigData config;
  final VoidCallback onEdit;
  const _SearchCriteriaCard({required this.config, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final chips = <_CritChip>[];
    for (final loc in config.locations) {
      chips.add(_CritChip(label: loc, icon: Icons.location_on_outlined));
    }
    if (config.examType.isNotEmpty) {
      chips.add(_CritChip(
        label: config.examType == 'Körprov'
            ? 'Uppkörning ${config.licenceType}'
            : config.examType,
        icon: config.licenceType.startsWith('A')
            ? Icons.motorcycle_rounded
            : Icons.directions_car_filled_rounded,
      ));
    }
    if (config.dateFrom.isNotEmpty || config.dateTo.isNotEmpty) {
      chips.add(_CritChip(
        label: _formatRange(config.dateFrom, config.dateTo),
        icon: Icons.calendar_today_rounded,
      ));
    }

    return BrandCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Expanded(
              child: Text(
                'Dina sökkriterier',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  letterSpacing: -0.3,
                ),
              ),
            ),
            InkWell(
              onTap: onEdit,
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.edit_outlined,
                        color: BrandPalette.lime, size: 15),
                    SizedBox(width: 4),
                    Text('Ändra',
                        style: TextStyle(
                          color: BrandPalette.lime,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        )),
                  ],
                ),
              ),
            ),
          ]),
          if (chips.isEmpty) ...[
            const SizedBox(height: 10),
            Text(
              'Inga filter satta – tryck Ändra för att välja ort, datum och provtyp.',
              style: TextStyle(
                color: Colors.white.withOpacity(0.65),
                fontSize: 13,
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 8, children: chips),
          ],
        ],
      ),
    );
  }

  static String _formatRange(String from, String to) {
    String fmt(String iso) {
      try {
        final p = iso.split('-');
        const months = ['jan', 'feb', 'mar', 'apr', 'maj', 'jun',
                        'jul', 'aug', 'sep', 'okt', 'nov', 'dec'];
        return '${int.parse(p[2])} ${months[int.parse(p[1]) - 1]}';
      } catch (_) {
        return iso;
      }
    }

    if (from.isEmpty && to.isEmpty) return '';
    if (from.isEmpty) return '– ${fmt(to)}';
    if (to.isEmpty) return '${fmt(from)} –';
    return '${fmt(from)} – ${fmt(to)}';
  }
}

class _CritChip extends StatelessWidget {
  final String label;
  final IconData icon;
  const _CritChip({required this.label, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: BrandPalette.lime.withOpacity(0.55), width: 1.2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: BrandPalette.lime),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12.5,
              )),
          const SizedBox(width: 6),
          const Icon(Icons.check_circle, color: BrandPalette.lime, size: 14),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// "Filtrera tider" bottom sheet — vertical rows with leading icon + label +
// lime check toggle, date range row with chevron, big lime "Visa lediga tider"
// CTA. Mirrors the second generated screenshot.
// ─────────────────────────────────────────────────────────────────────────────
class _FilterSheet extends StatefulWidget {
  final ApiClient api;
  final AppConfigData initial;
  const _FilterSheet({required this.api, required this.initial});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late Set<String> _locations;
  late String _licence;
  late String _exam;
  late String _from;
  late String _to;
  List<LocationDetail> _allLocations = [];
  bool _loadingLocations = true;

  static const _licenceTypes = ['B', 'A', 'A1', 'A2'];
  static const _examTypes = ['Körprov', 'Kunskapsprov'];

  @override
  void initState() {
    super.initState();
    _locations = widget.initial.locations.toSet();
    _licence = widget.initial.licenceType;
    _exam = widget.initial.examType;
    _from = widget.initial.dateFrom;
    _to = widget.initial.dateTo;
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    try {
      final list = await widget.api.locationDetails();
      if (mounted) {
        setState(() {
          _allLocations = list;
          _loadingLocations = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingLocations = false);
    }
  }

  Future<void> _pickDateRange() async {
    final now = DateTime.now();
    DateTime parse(String iso, DateTime fallback) {
      try {
        final p = iso.split('-');
        return DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      } catch (_) {
        return fallback;
      }
    }

    final initialFrom = _from.isEmpty ? now : parse(_from, now);
    final initialTo =
        _to.isEmpty ? now.add(const Duration(days: 45)) : parse(_to, now);

    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 2),
      initialDateRange: DateTimeRange(start: initialFrom, end: initialTo),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.dark(
            primary: BrandPalette.lime,
            onPrimary: BrandPalette.ink,
            surface: BrandPalette.ink,
            onSurface: Colors.white,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      String iso(DateTime d) =>
          '${d.year.toString().padLeft(4, "0")}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}';
      setState(() {
        _from = iso(picked.start);
        _to = iso(picked.end);
      });
    }
  }

  String _dateLabel() {
    if (_from.isEmpty && _to.isEmpty) return 'Välj datumintervall';
    return _SearchCriteriaCard._formatRange(_from, _to);
  }

  void _showLocationPicker() {
    if (_loadingLocations || _allLocations.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: BrandPalette.ink,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, sbSet) => SafeArea(
          child: SizedBox(
            height: MediaQuery.of(context).size.height * 0.75,
            child: Column(children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
                child: Text('Välj orter',
                    style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 18)),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: _allLocations.length,
                  itemBuilder: (_, i) {
                    final loc = _allLocations[i];
                    final label = loc.region.isEmpty
                        ? loc.name
                        : '${loc.region} · ${loc.name}';
                    final selected = _locations.contains(label);
                    return ListTile(
                      title: Text(label,
                          style: const TextStyle(color: Colors.white)),
                      trailing: selected
                          ? const Icon(Icons.check_circle,
                              color: BrandPalette.lime)
                          : Icon(Icons.circle_outlined,
                              color: Colors.white.withOpacity(0.25)),
                      onTap: () => sbSet(() {
                        setState(() {
                          if (selected) {
                            _locations.remove(label);
                          } else {
                            _locations.add(label);
                          }
                        });
                      }),
                    );
                  },
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: BrandCTA(
                  label: 'Klar',
                  onPressed: () => Navigator.pop(ctx),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  void _pickFromChoice(List<String> options, String current,
      ValueChanged<String> onPick, String title) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: BrandPalette.ink,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Text(title,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 18)),
            ),
            for (final o in options)
              ListTile(
                title: Text(o, style: const TextStyle(color: Colors.white)),
                trailing: o == current
                    ? const Icon(Icons.check_rounded, color: BrandPalette.lime)
                    : null,
                onTap: () {
                  onPick(o);
                  Navigator.pop(ctx);
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  String get _locationsLabel {
    if (_locations.isEmpty) return 'Välj ort';
    if (_locations.length == 1) return _locations.first;
    return '${_locations.first} +${_locations.length - 1}';
  }

  String get _licenceLabel {
    if (_exam == 'Kunskapsprov') return 'Kunskapsprov $_licence';
    return 'Uppkörning $_licence';
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.6,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, controller) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF0B0B0F),
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(20, 14, 20, 24),
            children: [
              Center(
                child: Container(
                  width: 44,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(children: [
                const Expanded(
                  child: Text(
                    'Filtrera tider',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                      fontSize: 24,
                      letterSpacing: -0.4,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: BrandPalette.surfaceMuted,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close_rounded,
                        color: Colors.white, size: 18),
                  ),
                ),
              ]),
              const SizedBox(height: 18),
              _FilterRow(
                icon: Icons.location_on_outlined,
                label: _locationsLabel,
                selected: _locations.isNotEmpty,
                onTap: _showLocationPicker,
              ),
              const SizedBox(height: 10),
              _FilterRow(
                icon: _licence.startsWith('A')
                    ? Icons.motorcycle_rounded
                    : Icons.directions_car_filled_rounded,
                label: _licenceLabel,
                selected: true,
                onTap: () => _pickFromChoice(
                  _licenceTypes,
                  _licence,
                  (v) => setState(() => _licence = v),
                  'Körkortstyp',
                ),
              ),
              const SizedBox(height: 10),
              _FilterRow(
                icon: Icons.menu_book_rounded,
                label: _exam,
                selected: true,
                onTap: () => _pickFromChoice(
                  _examTypes,
                  _exam,
                  (v) => setState(() => _exam = v),
                  'Provtyp',
                ),
              ),
              const SizedBox(height: 10),
              _FilterRow(
                icon: Icons.calendar_today_rounded,
                label: _dateLabel(),
                selected: _from.isNotEmpty || _to.isNotEmpty,
                trailingIcon: Icons.chevron_right_rounded,
                onTap: _pickDateRange,
              ),
              const SizedBox(height: 22),
              BrandCTA(
                label: 'Visa lediga tider',
                icon: Icons.search_rounded,
                onPressed: () {
                  Navigator.pop(
                    context,
                    widget.initial.copyWith(
                      locations: _locations.toList(),
                      licenceType: _licence,
                      examType: _exam,
                      dateFrom: _from,
                      dateTo: _to,
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final IconData? trailingIcon;
  final VoidCallback onTap;
  const _FilterRow({
    required this.icon,
    required this.label,
    required this.selected,
    this.trailingIcon,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            color: BrandPalette.surface,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: Colors.white.withOpacity(0.06),
              width: 1,
            ),
          ),
          child: Row(children: [
            Icon(icon, color: BrandPalette.lime, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15.5,
                  letterSpacing: -0.2,
                ),
              ),
            ),
            if (trailingIcon != null)
              Icon(trailingIcon,
                  color: Colors.white.withOpacity(0.45), size: 22)
            else if (selected)
              Container(
                width: 26,
                height: 26,
                decoration: const BoxDecoration(
                  color: BrandPalette.lime,
                  shape: BoxShape.circle,
                ),
                child:
                    const Icon(Icons.check_rounded, color: BrandPalette.ink, size: 16),
              )
            else
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withOpacity(0.25),
                    width: 1.4,
                  ),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Slot detail sheet — "Ledig tid" preview with large date/time, location,
// test type and a big lime "Boka nu" CTA. Pops `true` to confirm booking.
// ─────────────────────────────────────────────────────────────────────────────
class _SlotDetailSheet extends StatelessWidget {
  final Slot slot;
  final String? examType;
  const _SlotDetailSheet({required this.slot, this.examType});

  static const _weekdays = [
    'Måndag', 'Tisdag', 'Onsdag', 'Torsdag', 'Fredag', 'Lördag', 'Söndag'
  ];
  static const _months = [
    'januari', 'februari', 'mars', 'april', 'maj', 'juni',
    'juli', 'augusti', 'september', 'oktober', 'november', 'december',
  ];

  String _longDate() {
    try {
      final p = slot.date.split('-');
      final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      return '${_weekdays[(d.weekday - 1) % 7]} ${d.day} ${_months[d.month - 1]}';
    } catch (_) {
      return slot.date;
    }
  }

  String _testType() {
    final raw = slot.name.trim();
    if (raw.isNotEmpty) return raw;
    if (examType != null && examType!.isNotEmpty) return examType!;
    return 'Förarprov';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF131318),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 14, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Ledig tid',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                      )),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(false),
                    child: Icon(Icons.close_rounded,
                        color: Colors.white.withOpacity(0.65), size: 22),
                  ),
                ],
              ),
              const SizedBox(height: 28),
              Center(
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      width: 96,
                      height: 96,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: BrandPalette.lime.withOpacity(0.10),
                        boxShadow: [
                          BoxShadow(
                            color: BrandPalette.lime.withOpacity(0.30),
                            blurRadius: 32,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 72,
                      height: 72,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: BrandPalette.lime,
                      ),
                      child: const Icon(Icons.event_available_rounded,
                          color: BrandPalette.ink, size: 36),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),
              Center(
                child: Text(
                  _longDate(),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Center(
                child: Text(
                  slot.time,
                  style: const TextStyle(
                    color: BrandPalette.lime,
                    fontSize: 44,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.2,
                    height: 1.05,
                  ),
                ),
              ),
              const SizedBox(height: 18),
              _DetailRow(icon: Icons.place_outlined, label: slot.location),
              const SizedBox(height: 10),
              _DetailRow(icon: Icons.assignment_outlined, label: _testType()),
              if (slot.cost.trim().isNotEmpty) ...[
                const SizedBox(height: 10),
                _DetailRow(icon: Icons.payments_outlined, label: slot.cost),
              ],
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A20),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white.withOpacity(0.05)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: const [
                    Text(
                      'Så slutför du bokningen',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.1,
                      ),
                    ),
                    SizedBox(height: 8),
                    _BookStep(n: '1', label: 'Identifiera dig med BankID'),
                    SizedBox(height: 4),
                    _BookStep(n: '2', label: 'Bekräfta tiden'),
                    SizedBox(height: 4),
                    _BookStep(n: '3', label: 'Betala med kort eller Swish'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              BrandCTA(
                label: 'Boka nu',
                onPressed: () => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Öppnas hos Trafikverket – ha BankID redo',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.55),
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookStep extends StatelessWidget {
  final String n;
  final String label;
  const _BookStep({required this.n, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: BrandPalette.lime,
          ),
          child: Text(
            n,
            style: const TextStyle(
              color: BrandPalette.ink,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: Colors.white.withOpacity(0.85),
              fontSize: 13,
              height: 1.25,
            ),
          ),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  const _DetailRow({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A20),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Row(
        children: [
          Icon(icon, color: BrandPalette.lime, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
