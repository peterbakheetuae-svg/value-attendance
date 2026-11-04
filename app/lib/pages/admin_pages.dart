import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'common.dart';

/// Departments + sales teams (team manager must be a Sales Manager — enforced by the DB too).
class OrgAdminPage extends StatefulWidget {
  const OrgAdminPage({super.key});
  @override
  State<OrgAdminPage> createState() => _OrgAdminPageState();
}

class _OrgAdminPageState extends State<OrgAdminPage> {
  Key _k = UniqueKey();
  void _refresh() => setState(() => _k = UniqueKey());

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('departments_and_teams'),
      body: AsyncView<List<Map<String, dynamic>>>(
        key: _k,
        load: () => Future.wait([s.api.get('/departments'), s.api.get('/teams'), s.api.get('/employees', {'role': 'sales_manager'})]),
        builder: (ctx, d, _) {
          final deps = d[0].list('departments'), teams = d[1].list('teams'), mgrs = d[2].list('employees');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SectionTitle(t('departments'), trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('add')), onPressed: () => _dept(context, null))),
            GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: deps.isEmpty ? EmptyState(t('none')) : Column(children: [
              for (final x in deps) ListTile(
                title: Text(x.s('name_ar'), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${x.s('name_en')} · ${t('n_employees', {'n': x['employee_count']})}'),
                trailing: x['active'] == true ? IconButton(icon: const Icon(Icons.edit), onPressed: () => _dept(context, x)) : StatusChip(t('inactive'), color: Colors.grey),
              ),
            ])),
            SectionTitle(t('sales_teams'), trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('add')), onPressed: () => _team(context, null, deps, mgrs))),
            GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: teams.isEmpty ? EmptyState(t('none')) : Column(children: [
              for (final x in teams) ListTile(
                title: Text(x.s('name'), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${t('sales_manager')}: ${x['manager_name'] ?? '—'} · ${t('n_employees', {'n': x['member_count']})}'),
                trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _team(context, x, deps, mgrs)),
              ),
            ])),
          ]);
        },
      ),
    );
  }

  Future<void> _dept(BuildContext context, Map<String, dynamic>? x) async {
    final ar = TextEditingController(text: x?.s('name_ar') ?? ''), en = TextEditingController(text: x?.s('name_en') ?? '');
    bool active = x?['active'] != false;
    await showGlassSheet(context, title: x == null ? t('add_department') : t('edit_department'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: ar, decoration: glassInput(ctx, t('name_ar'))),
      const SizedBox(height: 10),
      TextField(controller: en, decoration: glassInput(ctx, t('name_en'))),
      if (x != null) SwitchListTile(contentPadding: EdgeInsets.zero, value: active, title: Text(t('active')), onChanged: (v) => set(() => active = v)),
      const SizedBox(height: 12),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          final api = context.read<Session>().api;
          if (x == null) { await api.post('/departments', {'nameAr': ar.text.trim(), 'nameEn': en.text.trim()}); }
          else { await api.patch('/departments/${x['id']}', {'nameAr': ar.text.trim(), 'nameEn': en.text.trim(), 'active': active}); }
          if (ctx.mounted) Navigator.pop(ctx);
          _refresh();
        } catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
      }),
    ])));
  }

  Future<void> _team(BuildContext context, Map<String, dynamic>? x, List<Map<String, dynamic>> deps, List<Map<String, dynamic>> mgrs) async {
    final name = TextEditingController(text: x?.s('name') ?? '');
    String? dept = x?['department_id']?.toString(), mgr = x?['manager_id']?.toString();
    bool active = x?['active'] != false;
    await showGlassSheet(context, title: x == null ? t('add_team') : t('edit_team'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: name, decoration: glassInput(ctx, t('team_name'))),
      const SizedBox(height: 10),
      DropdownButtonFormField<String?>(value: deps.any((d) => d['id'] == dept) ? dept : null, isExpanded: true, decoration: glassInput(ctx, t('department')),
          items: [DropdownMenuItem<String?>(value: null, child: Text(t('none'))), for (final d in deps) DropdownMenuItem<String?>(value: d.s('id'), child: Text(d.s('name_ar')))],
          onChanged: (v) => set(() => dept = v)),
      const SizedBox(height: 10),
      DropdownButtonFormField<String?>(value: mgrs.any((m) => m['id'] == mgr) ? mgr : null, isExpanded: true, decoration: glassInput(ctx, t('sales_manager')),
          items: [DropdownMenuItem<String?>(value: null, child: Text(t('none'))), for (final m in mgrs) DropdownMenuItem<String?>(value: m.s('id'), child: Text(m.s('full_name')))],
          onChanged: (v) => set(() => mgr = v)),
      if (x != null) SwitchListTile(contentPadding: EdgeInsets.zero, value: active, title: Text(t('active')), onChanged: (v) => set(() => active = v)),
      const SizedBox(height: 12),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          final api = context.read<Session>().api;
          final body = {'name': name.text.trim(), 'departmentId': dept, 'managerId': mgr};
          if (x == null) { await api.post('/teams', body); } else { await api.patch('/teams/${x['id']}', {...body, 'active': active}); }
          if (ctx.mounted) Navigator.pop(ctx);
          _refresh();
        } catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
      }),
    ])));
  }
}

/// Work schedules, public holidays and office geofences.
class AttendanceConfigPage extends StatefulWidget {
  const AttendanceConfigPage({super.key});
  @override
  State<AttendanceConfigPage> createState() => _AttendanceConfigPageState();
}

class _AttendanceConfigPageState extends State<AttendanceConfigPage> {
  Key _k = UniqueKey();
  void _refresh() => setState(() => _k = UniqueKey());
  static const _dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('schedules_holidays_locations'),
      body: AsyncView<List<Map<String, dynamic>>>(
        key: _k,
        load: () => Future.wait([s.api.get('/schedules'), s.api.get('/holidays', {'year': '${DateTime.now().year}'}), s.api.get('/work-locations')]),
        builder: (ctx, d, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SectionTitle(t('work_schedules'), trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('add')), onPressed: () => _schedule(context, null))),
          GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Column(children: [
            for (final x in d[0].list('schedules')) ListTile(
              title: Text('${x.s('name')}${x['is_default'] == true ? ' · ${t('default')}' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${x.s('start_time').substring(0, 5)} → ${x.s('end_time').substring(0, 5)} · ${t('grace')} ${x['late_grace_minutes']}${t('min_short')} · '
                  '${t('weekend')}: ${(x['weekend_days'] as List).map((n) => t('day_${_dayKeys[(n as int) - 1]}')).join('، ')}'
                  '${x['overtime_enabled'] == true ? ' · ${t('overtime_enabled')}' : ''}'),
              trailing: IconButton(icon: const Icon(Icons.edit), onPressed: () => _schedule(context, x)),
            ),
          ])),
          SectionTitle('${t('public_holidays')} ${DateTime.now().year}', trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('add')), onPressed: () => _holiday(context))),
          GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: d[1].list('holidays').isEmpty ? EmptyState(t('none')) : Column(children: [
            for (final h in d[1].list('holidays')) ListTile(
              title: Text(h.s('name')), subtitle: Text(Fmt.date(h['day'])),
              trailing: IconButton(icon: const Icon(Icons.delete_outline, color: AppColors.error), onPressed: () async {
                final ok = await confirmDialog(context, title: t('delete'), message: h.s('name'), ok: t('delete'), cancel: t('cancel'));
                if (!ok || !context.mounted) return;
                try { await s.api.delete('/holidays/${h['id']}'); _refresh(); } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
              }),
            ),
          ])),
          SectionTitle(t('office_locations'), trailing: TextButton.icon(icon: const Icon(Icons.add), label: Text(t('add')), onPressed: () => _location(context, null))),
          Text(t('gps_locations_note'), style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: d[2].list('locations').isEmpty ? EmptyState(t('none')) : Column(children: [
            for (final l in d[2].list('locations')) ListTile(
              title: Text(l.s('name'), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${(l['lat'] as num).toStringAsFixed(5)}, ${(l['lng'] as num).toStringAsFixed(5)} · ${l['radius_m']}m'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                if (l['active'] != true) StatusChip(t('inactive'), color: Colors.grey),
                IconButton(icon: const Icon(Icons.edit), onPressed: () => _location(context, l)),
              ]),
            ),
          ])),
        ]),
      ),
    );
  }

  Future<void> _schedule(BuildContext context, Map<String, dynamic>? x) async {
    final name = TextEditingController(text: x?.s('name') ?? '');
    TimeOfDay start = _tod(x?['start_time'] ?? '10:00'), end = _tod(x?['end_time'] ?? '18:00');
    final grace = TextEditingController(text: '${x?['late_grace_minutes'] ?? 15}');
    final early = TextEditingController(text: '${x?['early_grace_minutes'] ?? 0}');
    final otMin = TextEditingController(text: '${x?['overtime_min_minutes'] ?? 30}');
    final weekend = <int>{...((x?['weekend_days'] as List?)?.cast<int>() ?? [5])};
    bool ot = x?['overtime_enabled'] == true;
    await showGlassSheet(context, title: x == null ? t('add_schedule') : t('edit_schedule'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: name, decoration: glassInput(ctx, t('name'))),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: OutlinedButton(onPressed: () async { final v = await pickTime(ctx, initial: start); if (v != null) set(() => start = v); }, child: Text('${t('start')}: ${hhmm(start)}'))),
        const SizedBox(width: 10),
        Expanded(child: OutlinedButton(onPressed: () async { final v = await pickTime(ctx, initial: end); if (v != null) set(() => end = v); }, child: Text('${t('end')}: ${hhmm(end)}'))),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: TextField(controller: grace, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('late_grace_minutes')))),
        const SizedBox(width: 10),
        Expanded(child: TextField(controller: early, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('early_grace_minutes')))),
      ]),
      const SizedBox(height: 10),
      Text(t('weekend_days')),
      Wrap(spacing: 6, children: [
        for (var i = 1; i <= 7; i++) FilterChip(label: Text(t('day_${_dayKeys[i - 1]}')), selected: weekend.contains(i),
            onSelected: (v) => set(() { if (v) { weekend.add(i); } else { weekend.remove(i); } })),
      ]),
      SwitchListTile(contentPadding: EdgeInsets.zero, value: ot, title: Text(t('overtime_enabled')), onChanged: (v) => set(() => ot = v)),
      if (ot) TextField(controller: otMin, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('overtime_min_minutes'))),
      const SizedBox(height: 12),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          final body = {'name': name.text.trim(), 'startTime': hhmm(start), 'endTime': hhmm(end),
            'lateGraceMinutes': int.parse(grace.text), 'earlyGraceMinutes': int.parse(early.text),
            'weekendDays': weekend.toList()..sort(), 'overtimeEnabled': ot, 'overtimeMinMinutes': int.parse(otMin.text)};
          final api = context.read<Session>().api;
          if (x == null) { await api.post('/schedules', body); } else { await api.patch('/schedules/${x['id']}', body); }
          if (ctx.mounted) Navigator.pop(ctx);
          _refresh();
        } catch (e) { if (ctx.mounted) showSnack(ctx, e is FormatException ? t('invalid_amount') : errorText(e), error: true); }
      }),
    ])));
  }

  TimeOfDay _tod(Object v) { final p = v.toString().split(':'); return TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])); }

  Future<void> _holiday(BuildContext context) async {
    final name = TextEditingController();
    DateTime? day;
    await showGlassSheet(context, title: t('add_holiday'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      OutlinedButton.icon(icon: const Icon(Icons.event), label: Text(day == null ? t('date') : Fmt.date(ymd(day!))),
          onPressed: () async { final d = await pickDate(ctx, initial: day); if (d != null) set(() => day = d); }),
      const SizedBox(height: 10),
      TextField(controller: name, decoration: glassInput(ctx, t('holiday_name'))),
      const SizedBox(height: 12),
      PrimaryButton(label: t('save'), onTap: () async {
        if (day == null) { showSnack(ctx, t('fill_required'), error: true); return; }
        try { await context.read<Session>().api.post('/holidays', {'day': ymd(day!), 'name': name.text.trim()}); if (ctx.mounted) Navigator.pop(ctx); _refresh(); }
        catch (e) { if (ctx.mounted) showSnack(ctx, errorText(e), error: true); }
      }),
    ])));
  }

  Future<void> _location(BuildContext context, Map<String, dynamic>? x) async {
    final name = TextEditingController(text: x?.s('name') ?? '');
    final lat = TextEditingController(text: x?['lat']?.toString() ?? ''), lng = TextEditingController(text: x?['lng']?.toString() ?? '');
    final radius = TextEditingController(text: '${x?['radius_m'] ?? 150}');
    bool active = x?['active'] != false;
    await showGlassSheet(context, title: x == null ? t('add_location') : t('edit_location'), child: StatefulBuilder(builder: (ctx, set) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: name, decoration: glassInput(ctx, t('name'))),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: TextField(controller: lat, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: glassInput(ctx, t('latitude')))),
        const SizedBox(width: 10),
        Expanded(child: TextField(controller: lng, keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true), decoration: glassInput(ctx, t('longitude')))),
      ]),
      Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(
        icon: const Icon(Icons.my_location_rounded),
        label: Text(t('use_my_location')),
        onPressed: () async {
          try {
            var p = await Geolocator.checkPermission();
            if (p == LocationPermission.denied) p = await Geolocator.requestPermission();
            final pos = await Geolocator.getCurrentPosition(locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)));
            set(() { lat.text = pos.latitude.toStringAsFixed(6); lng.text = pos.longitude.toStringAsFixed(6); });
            if (ctx.mounted) showSnack(ctx, t('location_accuracy_m', {'m': pos.accuracy.round()}));
          } catch (_) {
            if (ctx.mounted) showSnack(ctx, t('gps_off'), error: true);
          }
        },
      )),
      TextField(controller: radius, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('radius_m'))),
      if (x != null) SwitchListTile(contentPadding: EdgeInsets.zero, value: active, title: Text(t('active')), onChanged: (v) => set(() => active = v)),
      const SizedBox(height: 12),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          final body = {'name': name.text.trim(), 'lat': double.parse(lat.text), 'lng': double.parse(lng.text), 'radiusM': int.parse(radius.text)};
          final api = context.read<Session>().api;
          if (x == null) { await api.post('/work-locations', body); } else { await api.patch('/work-locations/${x['id']}', {...body, 'active': active}); }
          if (ctx.mounted) Navigator.pop(ctx);
          _refresh();
        } catch (e) { if (ctx.mounted) showSnack(ctx, e is FormatException ? t('invalid_amount') : errorText(e), error: true); }
      }),
    ])));
  }
}

class CompanySettingsPage extends StatelessWidget {
  const CompanySettingsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(title: t('company_settings'), body: AsyncView<Map<String, dynamic>>(
      load: () => s.api.get('/settings'),
      builder: (ctx, d, reload) {
        final st = d.obj('settings')!;
        final ar = TextEditingController(text: st.s('company_name_ar')), en = TextEditingController(text: st.s('company_name_en'));
        final back = TextEditingController(text: '${st['request_backdate_days']}');
        final brk = TextEditingController(text: '${st['break_minutes'] ?? 60}');
        bool gps = st['gps_required'] == true;
        bool pin = st['allow_pin'] == true, bind = st['device_binding'] == true, selfie = st['selfie_required'] == true;
        final keep = TextEditingController(text: '${st['selfie_retention_days'] ?? 30}');
        bool track = st['tracking_enabled'] == true;
        final remind = TextEditingController(text: '${st['checkin_reminder_minutes'] ?? 30}');
        final every = TextEditingController(text: '${st['tracking_interval_minutes'] ?? 5}');
        final stale = TextEditingController(text: '${st['tracking_stale_minutes'] ?? 20}');
        final margin = TextEditingController(text: '${st['away_margin_m'] ?? 100}');
        return StatefulBuilder(builder: (ctx, set) => GlassCard(radius: 20, child: Material(type: MaterialType.transparency, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: ar, decoration: glassInput(ctx, t('company_name_ar'))),
          const SizedBox(height: 10),
          TextField(controller: en, decoration: glassInput(ctx, t('company_name_en'))),
          const SizedBox(height: 10),
          TextField(controller: back, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('request_backdate_days'))),
          const SizedBox(height: 12),
          TextField(controller: brk, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('break_minutes'))),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: gps, title: Text(t('gps_required')), subtitle: Text(t('gps_required_help')), onChanged: (v) => set(() => gps = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: pin, title: Text(t('allow_pin')), subtitle: Text(t('allow_pin_help')), onChanged: (v) => set(() => pin = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: bind, title: Text(t('device_binding')), subtitle: Text(t('device_binding_help')), onChanged: (v) => set(() => bind = v)),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: selfie, title: Text(t('selfie_required')), subtitle: Text(t('selfie_required_help')), onChanged: (v) => set(() => selfie = v)),
          TextField(controller: keep, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('selfie_retention_days'))),
          const SizedBox(height: 12),
          TextField(controller: remind, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('checkin_reminder_minutes'))),
          SwitchListTile(contentPadding: EdgeInsets.zero, value: track, title: Text(t('tracking_enabled')), subtitle: Text(t('tracking_enabled_help')), onChanged: (v) => set(() => track = v)),
          if (track) ...[
            Row(children: [
              Expanded(child: TextField(controller: every, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('tracking_interval_minutes')))),
              const SizedBox(width: 8),
              Expanded(child: TextField(controller: stale, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('tracking_stale_minutes')))),
            ]),
            const SizedBox(height: 10),
            TextField(controller: margin, keyboardType: TextInputType.number, decoration: glassInput(ctx, t('away_margin_m'))),
          ],
          const SizedBox(height: 8),
          InfoTile(title: t('currency'), value: 'EGP'),
          const SizedBox(height: 12),
          PrimaryButton(label: t('save'), onTap: () async {
            try {
              await s.api.patch('/settings', {'companyNameAr': ar.text.trim(), 'companyNameEn': en.text.trim(), 'gpsRequired': gps, 'requestBackdateDays': int.parse(back.text), 'breakMinutes': int.parse(brk.text),
                'allowPin': pin, 'deviceBinding': bind, 'selfieRequired': selfie, 'selfieRetentionDays': int.parse(keep.text),
                'checkinReminderMinutes': int.parse(remind.text), 'trackingEnabled': track,
                'trackingIntervalMinutes': int.parse(every.text), 'trackingStaleMinutes': int.parse(stale.text), 'awayMarginM': int.parse(margin.text)});
              await s.refreshMe();
              if (ctx.mounted) showSnack(ctx, t('saved'));
            } catch (e) { if (ctx.mounted) showSnack(ctx, e is FormatException ? t('invalid_amount') : errorText(e), error: true); }
          }),
        ]))));
      },
    ));
  }
}

class RolesPage extends StatefulWidget {
  const RolesPage({super.key});
  @override
  State<RolesPage> createState() => _RolesPageState();
}

class _RolesPageState extends State<RolesPage> {
  Key _k = UniqueKey();
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(title: t('roles_permissions'), body: AsyncView<Map<String, dynamic>>(
      key: _k,
      load: () => s.api.get('/roles'),
      builder: (ctx, d, _) {
        final perms = d.list('permissions');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(t('roles_note'), style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 8),
          for (final r in d.list('roles')) Padding(padding: const EdgeInsets.only(bottom: 10), child: GlassCard(radius: 20, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(I18n.lang == 'ar' ? r.s('name_ar') : r.s('name_en'), style: const TextStyle(fontWeight: FontWeight.w800)),
            subtitle: Text(t('n_permissions', {'n': (r['permissions'] as List).length})),
            children: [
              for (final p in perms) CheckboxListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: (r['permissions'] as List).contains(p['key']),
                title: Text(t('perm_${p.s('key').replaceAll('.', '_')}')),
                subtitle: Text(p.s('key'), style: const TextStyle(fontSize: 11)),
                onChanged: (r['key'] == 'owner' || r['key'] == 'sales_employee') ? null : (v) async {
                  final next = {...(r['permissions'] as List).cast<String>()};
                  if (v == true) { next.add(p.s('key')); } else { next.remove(p.s('key')); }
                  try { await s.api.put('/roles/${r['key']}/permissions', {'permissions': next.toList()}); setState(() => _k = UniqueKey()); }
                  catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
                },
              ),
            ],
          ))),
        ]);
      },
    ));
  }
}

class AuditPage extends StatelessWidget {
  const AuditPage({super.key});
  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(title: t('audit_log'), body: AsyncView<Map<String, dynamic>>(
      load: () => s.api.get('/audit', {'limit': '200'}),
      builder: (ctx, d, _) => GlassCard(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Column(children: [
        for (final e in d.list('entries')) ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: const Icon(Icons.history_rounded),
          title: Text(t('audit_${e.s('action').replaceAll('.', '_')}')),
          subtitle: Text('${e['actor_name'] ?? '—'} · ${e.s('entity')} · ${Fmt.dateTime(e['at'])}'),
        ),
      ])),
    ));
  }
}

/// Payroll rules (Value HR): day divisor, per-minute or tiered late/early deductions, absence penalty.
class PayrollRulesPage extends StatefulWidget {
  const PayrollRulesPage({super.key});
  @override
  State<PayrollRulesPage> createState() => _PayrollRulesPageState();
}

class _TierRow {
  final TextEditingController minutes;
  final TextEditingController amount;
  _TierRow(Object? m, Object? a)
      : minutes = TextEditingController(text: m == null ? '' : '$m'),
        amount = TextEditingController(text: a == null ? '' : '$a');
}

class _PayrollRulesPageState extends State<PayrollRulesPage> {
  bool _loaded = false, _saving = false;
  bool _auto = false;
  int _divisor = 30;
  String _mode = 'per_minute';
  final _absence = TextEditingController();
  final List<_TierRow> _late = [], _early = [];
  Object? _error;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    try {
      final st = (await context.read<Session>().api.get('/settings')).obj('settings')!;
      List<_TierRow> rows(Object? v) => [for (final x in (v as List? ?? const [])) _TierRow((x as Map)['afterMinutes'], x['amount'])];
      setState(() {
        _auto = st['payroll_auto_deductions'] == true;
        _divisor = (st['day_divisor'] ?? 30) as int;
        _mode = st.s('deduction_mode').isEmpty ? 'per_minute' : st.s('deduction_mode');
        _absence.text = '${st['absence_penalty_days'] ?? 1}';
        _late..clear()..addAll(rows(st['late_tiers']));
        _early..clear()..addAll(rows(st['early_tiers']));
        _loaded = true;
      });
    } catch (e) {
      setState(() => _error = e);
    }
  }

  List<Map<String, num>> _tiers(List<_TierRow> rows) => [
        for (final r in rows)
          if (r.minutes.text.trim().isNotEmpty || r.amount.text.trim().isNotEmpty)
            {'afterMinutes': int.parse(r.minutes.text.trim()), 'amount': num.parse(r.amount.text.trim())},
      ];

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await context.read<Session>().api.patch('/settings', {
        'payrollAutoDeductions': _auto, 'dayDivisor': _divisor, 'deductionMode': _mode,
        'absencePenaltyDays': num.parse(_absence.text.trim()),
        'lateTiers': _tiers(_late), 'earlyTiers': _tiers(_early),
      });
      if (mounted) showSnack(context, t('saved'));
    } catch (e) {
      if (mounted) showSnack(context, e is FormatException ? t('tiers_invalid') : errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _tierEditor(String title, List<_TierRow> rows) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SectionTitle(title),
        for (var i = 0; i < rows.length; i++) Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(children: [
            Expanded(child: TextField(controller: rows[i].minutes, keyboardType: TextInputType.number, decoration: glassInput(context, t('tier_after_minutes')))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: rows[i].amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: glassInput(context, t('amount_egp')))),
            IconButton(icon: const Icon(Icons.delete_outline_rounded, color: AppColors.error), onPressed: () => setState(() => rows.removeAt(i))),
          ]),
        ),
        if (rows.length < 6) Align(alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(icon: const Icon(Icons.add_rounded), label: Text(t('add_tier')), onPressed: () => setState(() => rows.add(_TierRow(null, null))))),
      ]);

  @override
  Widget build(BuildContext context) {
    return GlassPage(
      title: t('payroll_rules'),
      body: _error != null
          ? ErrorState(errorText(_error!), onRetry: _load, retryLabel: t('retry'))
          : !_loaded
              ? const LoadingState()
              : GlassCard(radius: 20, child: Material(type: MaterialType.transparency, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  SwitchListTile(contentPadding: EdgeInsets.zero, value: _auto, title: Text(t('auto_deductions')), subtitle: Text(t('auto_deductions_help')),
                      onChanged: (v) => setState(() => _auto = v)),
                  const SizedBox(height: 8),
                  Text(t('day_divisor')),
                  const SizedBox(height: 6),
                  SegmentedButton<int>(segments: const [ButtonSegment(value: 26, label: Text('26')), ButtonSegment(value: 30, label: Text('30'))],
                      selected: {_divisor}, onSelectionChanged: (v) => setState(() => _divisor = v.first)),
                  const SizedBox(height: 14),
                  Text(t('deduction_mode')),
                  const SizedBox(height: 6),
                  SegmentedButton<String>(segments: [
                    ButtonSegment(value: 'per_minute', label: Text(t('mode_per_minute'))),
                    ButtonSegment(value: 'tiers', label: Text(t('mode_tiers'))),
                  ], selected: {_mode}, onSelectionChanged: (v) => setState(() => _mode = v.first)),
                  const SizedBox(height: 6),
                  Text(_mode == 'per_minute' ? t('mode_per_minute_help') : t('mode_tiers_help'), style: const TextStyle(fontSize: 12)),
                  if (_mode == 'tiers') ...[
                    _tierEditor(t('late_tiers'), _late),
                    _tierEditor(t('early_tiers'), _early),
                  ],
                  const SizedBox(height: 14),
                  TextField(controller: _absence, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: glassInput(context, t('absence_penalty_days'))),
                  const SizedBox(height: 16),
                  PrimaryButton(label: t('save'), loading: _saving, onTap: _save),
                ]))),
    );
  }
}
