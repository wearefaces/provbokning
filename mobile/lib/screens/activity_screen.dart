import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/glass.dart';

class ActivityScreen extends StatefulWidget {
  final ApiClient api;
  const ActivityScreen({super.key, required this.api});

  @override
  State<ActivityScreen> createState() => _ActivityScreenState();
}

class _ActivityScreenState extends State<ActivityScreen> {
  List<ActivityEntry> _entries = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await widget.api.activityLog();
      if (!mounted) return;
      setState(() {
        _entries = list.reversed.toList(); // newest first
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: RefreshIndicator(
        color: GlassPalette.accentSoft,
        backgroundColor: const Color(0xFF1A2042),
        onRefresh: _refresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 120),
          children: [
            const SectionHeader('Aktivitet',
                subtitle: 'Senaste händelser och notiser'),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 60),
                child: Center(
                    child: CircularProgressIndicator(
                        color: GlassPalette.accentSoft)),
              )
            else if (_error != null)
              GlassPanel(
                tint: GlassPalette.danger,
                child: Text('Fel: $_error',
                    style: const TextStyle(color: Colors.white)),
              )
            else if (_entries.isEmpty)
              GlassPanel(
                padding: const EdgeInsets.all(28),
                child: Column(children: [
                  Icon(Icons.inbox_outlined,
                      size: 44, color: Colors.white.withOpacity(0.5)),
                  const SizedBox(height: 8),
                  const Text('Ingen aktivitet ännu.',
                      style: TextStyle(color: GlassPalette.textSecondary)),
                ]),
              )
            else
              ..._entries.map((e) => _ActivityTile(entry: e)),
          ],
        ),
      ),
    );
  }
}

class _ActivityTile extends StatelessWidget {
  final ActivityEntry entry;
  const _ActivityTile({required this.entry});

  ({IconData icon, Color color, String title, String detail}) _meta() {
    final r = entry.raw;
    switch (entry.type) {
      case 'found':
        final s = r['slot'] as Map?;
        return (
          icon: Icons.event_available_rounded,
          color: GlassPalette.success,
          title: 'Tid hittad',
          detail: s == null
              ? ''
              : '${s['date'] ?? ''} ${s['time'] ?? ''} – ${s['location'] ?? ''}',
        );
      case 'booked':
        return (
          icon: Icons.check_circle_rounded,
          color: GlassPalette.accentSoft,
          title: 'Bokad',
          detail: 'Reservation ${r['reservation_id'] ?? ''}',
        );
      case 'sms_sent':
        return (
          icon: Icons.sms_rounded,
          color: GlassPalette.success,
          title: 'SMS skickat',
          detail:
              '${r['recipients'] ?? 0} mottagare · ${r['notified_count'] ?? 0} tider',
        );
      case 'sms_failed':
        return (
          icon: Icons.sms_failed_rounded,
          color: GlassPalette.danger,
          title: 'SMS misslyckades',
          detail: '${r['recipients'] ?? 0} mottagare',
        );
      case 'email_sent':
        return (
          icon: Icons.mail_rounded,
          color: GlassPalette.success,
          title: 'E-post skickad',
          detail:
              '${r['recipients'] ?? 0} mottagare · ${r['notified_count'] ?? 0} tider',
        );
      case 'email_failed':
        return (
          icon: Icons.mark_email_read_outlined,
          color: GlassPalette.danger,
          title: 'E-post misslyckades',
          detail: '',
        );
      case 'ntfy_sent':
        return (
          icon: Icons.notifications_active_rounded,
          color: GlassPalette.success,
          title: 'Push-notis skickad',
          detail: '${r['topic'] ?? ''}',
        );
      case 'ntfy_failed':
        return (
          icon: Icons.notifications_off_rounded,
          color: GlassPalette.danger,
          title: 'Push-notis misslyckades',
          detail: '${r['topic'] ?? ''}',
        );
      case 'notify_skipped':
        return (
          icon: Icons.do_not_disturb_on_rounded,
          color: GlassPalette.warning,
          title: 'Notis hoppades över',
          detail: '${r['notified_count'] ?? 0} tider · ingen kanal aktiv',
        );
      default:
        return (
          icon: Icons.bolt_rounded,
          color: GlassPalette.textSecondary,
          title: entry.type,
          detail: '',
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _meta();
    return GlassPanel(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: m.color.withOpacity(0.25),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: m.color.withOpacity(0.5)),
            ),
            child: Icon(m.icon, color: Colors.white, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.title,
                    style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                        fontSize: 14)),
                if (m.detail.isNotEmpty)
                  Text(m.detail,
                      style: const TextStyle(
                          color: GlassPalette.textSecondary,
                          fontSize: 12)),
                const SizedBox(height: 2),
                Text(_fmtTime(entry.time),
                    style: const TextStyle(
                        color: GlassPalette.textMuted, fontSize: 11)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmtTime(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      return '${dt.year}-${_p(dt.month)}-${_p(dt.day)} ${_p(dt.hour)}:${_p(dt.minute)}';
    } catch (_) {
      return iso;
    }
  }

  String _p(int n) => n.toString().padLeft(2, '0');
}
