import 'dart:ui';
import 'package:flutter/material.dart';
import '../api.dart';
import '../models.dart';
import '../theme.dart';
import '../widgets/glass.dart';

class SettingsScreen extends StatefulWidget {
  final ApiClient api;
  const SettingsScreen({super.key, required this.api});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  AppConfigData _cfg = AppConfigData.empty();
  List<LocationDetail> _allLocations = [];
  bool _loading = true;
  bool _saving = false;
  String? _msg;

  final _ssn = TextEditingController();
  final _smsTo = TextEditingController();
  final _from = TextEditingController();
  final _to = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ssn.dispose();
    _smsTo.dispose();
    _from.dispose();
    _to.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final results = await Future.wait([
        widget.api.getConfig(),
        widget.api.locationDetails(),
      ]);
      final cfg = results[0] as AppConfigData;
      final locs = results[1] as List<LocationDetail>;
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _allLocations = locs;
        _ssn.text = cfg.swedishSsn;
        _smsTo.text = cfg.smsTo;
        _from.text = cfg.dateFrom;
        _to.text = cfg.dateTo;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _msg = 'Kunde inte ladda inställningar: $e';
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _msg = null;
    });
    final cfg = _cfg.copyWith(
      swedishSsn: _ssn.text.trim(),
      smsTo: _smsTo.text.trim(),
      dateFrom: _from.text.trim(),
      dateTo: _to.text.trim(),
    );
    try {
      await widget.api.saveConfig(cfg.toJson());
      if (!mounted) return;
      setState(() {
        _cfg = cfg;
        _saving = false;
        _msg = 'Sparat ✓';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _msg = 'Fel vid sparande: $e';
      });
    }
  }

  Future<void> _pickLocations() async {
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _LocationsPicker(
        all: _allLocations,
        selected: _cfg.locations.toSet(),
      ),
    );
    if (result != null) {
      setState(() => _cfg = _cfg.copyWith(locations: result));
    }
  }

  Future<void> _pickDate(TextEditingController c, {bool isFrom = true}) async {
    final initial =
        DateTime.tryParse(c.text) ?? DateTime.now().add(const Duration(days: 1));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.dark(
            primary: GlassPalette.accent,
            surface: const Color(0xFF1A2042),
            onPrimary: Colors.white,
            onSurface: Colors.white,
          ),
          dialogBackgroundColor: const Color(0xFF11183A),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      c.text = picked.toIso8601String().split('T').first;
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 120),
        children: [
          const SectionHeader('Inställningar',
              subtitle: 'Personuppgifter, körkortstyp och bevakade orter'),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 60),
              child: Center(
                  child: CircularProgressIndicator(
                      color: GlassPalette.accentSoft)),
            )
          else ...[
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GlassField(
                    controller: _ssn,
                    label: 'Personnummer',
                    hint: 'YYYYMMDDXXXX',
                    keyboardType: TextInputType.number,
                    icon: Icons.badge_outlined,
                    maxLength: 12,
                  ),
                  const SizedBox(height: 14),
                  const _Label('Körkortsbehörighet'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ['B', 'A', 'A1', 'A2']
                        .map((l) => GlassChip(
                              label: l,
                              selected: _cfg.licenceType == l,
                              onTap: () => setState(
                                  () => _cfg = _cfg.copyWith(licenceType: l)),
                            ))
                        .toList(),
                  ),
                  const SizedBox(height: 14),
                  const _Label('Provtyp'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: ['Körprov', 'Kunskapsprov']
                        .map((t) => GlassChip(
                              label: t,
                              selected: _cfg.examType == t,
                              onTap: () => setState(
                                  () => _cfg = _cfg.copyWith(examType: t)),
                            ))
                        .toList(),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const _Label('Datumintervall'),
                  const SizedBox(height: 6),
                  Row(children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _pickDate(_from, isFrom: true),
                        child: AbsorbPointer(
                          child: GlassField(
                            controller: _from,
                            label: 'Från',
                            hint: '2026-01-01',
                            icon: Icons.calendar_today_rounded,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _pickDate(_to, isFrom: false),
                        child: AbsorbPointer(
                          child: GlassField(
                            controller: _to,
                            label: 'Till',
                            hint: '2026-12-31',
                            icon: Icons.event_rounded,
                          ),
                        ),
                      ),
                    ),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              onTap: _pickLocations,
              child: Row(
                children: [
                  const Icon(Icons.place_outlined, color: Colors.white),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Bevakade orter',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                        const SizedBox(height: 2),
                        Text(
                          _cfg.locations.isEmpty
                              ? 'Alla orter'
                              : _cfg.locations.join(', '),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: GlassPalette.textSecondary, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.chevron_right_rounded,
                      color: GlassPalette.textSecondary),
                ],
              ),
            ),
            const SizedBox(height: 14),
            GlassPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.sms_rounded, color: Colors.white),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text('SMS-notiser',
                            style: TextStyle(
                                color: Colors.white,
                                fontWeight: FontWeight.w700,
                                fontSize: 15)),
                      ),
                      Switch(
                        value: _cfg.smsEnabled,
                        activeColor: GlassPalette.accent,
                        onChanged: (v) =>
                            setState(() => _cfg = _cfg.copyWith(smsEnabled: v)),
                      ),
                    ],
                  ),
                  if (_cfg.smsEnabled) ...[
                    const SizedBox(height: 10),
                    GlassField(
                      controller: _smsTo,
                      label: 'Mobilnummer',
                      hint: '+46701234567',
                      keyboardType: TextInputType.phone,
                      icon: Icons.phone_iphone_rounded,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 18),
            GlassButton(
              label: _saving ? 'Sparar…' : 'Spara inställningar',
              icon: Icons.check_rounded,
              onPressed: _saving ? null : _save,
              loading: _saving,
              expand: true,
            ),
            if (_msg != null) ...[
              const SizedBox(height: 12),
              Center(
                child: Text(_msg!,
                    style: const TextStyle(color: GlassPalette.textSecondary)),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Text(text,
            style: const TextStyle(
                color: GlassPalette.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 13)),
      );
}

class _LocationsPicker extends StatefulWidget {
  final List<LocationDetail> all;
  final Set<String> selected;
  const _LocationsPicker({required this.all, required this.selected});

  @override
  State<_LocationsPicker> createState() => _LocationsPickerState();
}

class _LocationsPickerState extends State<_LocationsPicker> {
  late Set<String> _sel;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _sel = {...widget.selected};
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.85;
    final filtered = widget.all.where((l) {
      if (_query.isEmpty) return true;
      final q = _query.toLowerCase();
      return l.name.toLowerCase().contains(q) ||
          l.region.toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    // Group by region
    final grouped = <String, List<LocationDetail>>{};
    for (final l in filtered) {
      grouped.putIfAbsent(l.region.isEmpty ? 'Övrigt' : l.region, () => []).add(l);
    }
    final regions = grouped.keys.toList()..sort();

    return Padding(
      padding: EdgeInsets.fromLTRB(
          12, 24, 12, MediaQuery.of(context).viewInsets.bottom + 12),
      child: SizedBox(
        height: h,
        child: GlassPanel(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          radius: 28,
          child: Column(
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.4),
                    borderRadius: BorderRadius.circular(4)),
              ),
              const SizedBox(height: 12),
              Row(children: [
                const Text('Välj orter',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800)),
                const Spacer(),
                Text('${_sel.length} valda',
                    style:
                        const TextStyle(color: GlassPalette.textSecondary)),
              ]),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: TextField(
                    style: const TextStyle(color: Colors.white),
                    cursorColor: GlassPalette.accentSoft,
                    onChanged: (v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Sök ort eller region…',
                      hintStyle:
                          const TextStyle(color: GlassPalette.textMuted),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.10),
                      prefixIcon: const Icon(Icons.search,
                          color: GlassPalette.textSecondary),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.18)),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide(
                            color: Colors.white.withOpacity(0.18)),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: const BorderSide(
                            color: GlassPalette.accentSoft, width: 1),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: ListView(
                  children: [
                    for (final region in regions) ...[
                      Padding(
                        padding:
                            const EdgeInsets.fromLTRB(6, 12, 6, 6),
                        child: Text(region,
                            style: const TextStyle(
                                color: GlassPalette.textMuted,
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                letterSpacing: 0.5)),
                      ),
                      ...grouped[region]!.map((l) {
                        final on = _sel.contains(l.name);
                        return InkWell(
                          borderRadius: BorderRadius.circular(12),
                          onTap: () => setState(() {
                            if (on) {
                              _sel.remove(l.name);
                            } else {
                              _sel.add(l.name);
                            }
                          }),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 10),
                            child: Row(children: [
                              Icon(
                                on
                                    ? Icons.check_circle_rounded
                                    : Icons.radio_button_unchecked,
                                color: on
                                    ? GlassPalette.accentSoft
                                    : GlassPalette.textMuted,
                              ),
                              const SizedBox(width: 12),
                              Text(l.name,
                                  style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w500)),
                            ]),
                          ),
                        );
                      }),
                    ],
                  ],
                ),
              ),
              Row(children: [
                Expanded(
                  child: GlassButton(
                    label: 'Avbryt',
                    primary: false,
                    onPressed: () => Navigator.of(context).pop(),
                    expand: true,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: GlassButton(
                    label: 'Spara',
                    icon: Icons.check_rounded,
                    onPressed: () =>
                        Navigator.of(context).pop(_sel.toList()..sort()),
                    expand: true,
                  ),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
