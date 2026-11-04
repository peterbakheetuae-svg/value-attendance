import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'attendance_page.dart';
import 'common.dart';
import 'evaluations_page.dart';
import 'kpi_page.dart';
import 'requests_page.dart';

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({super.key});
  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  final _q = TextEditingController();
  String _status = 'active';
  Key _k = UniqueKey();

  @override
  void dispose() { _q.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return Stack(children: [
      RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () async => setState(() => _k = UniqueKey()),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(title: s.has('employee.read_all') ? t('employees') : t('my_team')),
            GlassCard(radius: 18, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: TextField(
              controller: _q,
              decoration: InputDecoration(border: InputBorder.none, hintText: t('search_employees'), prefixIcon: const Icon(Icons.search)),
              onSubmitted: (_) => setState(() => _k = UniqueKey()),
            )),
            const SizedBox(height: 10),
            if (s.has('employee.manage')) FilterChips<String>(options: [('active', t('active')), ('inactive', t('inactive')), ('all', t('all'))],
                value: _status, onChanged: (v) => setState(() { _status = v; _k = UniqueKey(); })),
            const SizedBox(height: 10),
            AsyncView<Map<String, dynamic>>(
              key: _k,
              load: () => s.api.get('/employees', {'q': _q.text.trim(), 'status': _status}),
              builder: (ctx, d, reload) {
                final list = d.list('employees').where((e) => e['id'] != s.id).toList();
                if (list.isEmpty) return EmptyState(t('no_employees'));
                return Column(children: [
                  for (final e in list) Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: GlassCard(
                      radius: 20,
                      onTap: () async {
                        await Navigator.push(context, MaterialPageRoute(builder: (_) => EmployeeProfilePage(id: e.s('id'))));
                        await reload();
                      },
                      child: Row(children: [
                        EmployeeAvatar(employeeId: e.s('id'), hasPhoto: e['has_photo'] == true),
                        const SizedBox(width: 12),
                        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.s('full_name'), style: const TextStyle(fontWeight: FontWeight.w800)),
                          Text([e.s('code'), e.s('job_title'), if (e['team_name'] != null) e.s('team_name')].where((x) => x.isNotEmpty).join(' · '),
                              style: const TextStyle(fontSize: 12)),
                        ])),
                        if (e['status'] == 'inactive') StatusChip(t('inactive'), color: Colors.grey)
                        else Text(I18n.lang == 'ar' ? e.s('role_name_ar') : e.s('role_name_en'), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      ]),
                    ),
                  ),
                ]);
              },
            ),
            const SizedBox(height: 120),
          ]),
        ),
      ),
      if (s.has('employee.manage'))
        PositionedDirectional(end: 20, bottom: 110, child: FloatingActionButton.extended(
          heroTag: 'add_employee',
          backgroundColor: AppColors.primary, foregroundColor: Colors.white,
          icon: const Icon(Icons.person_add_alt_1), label: Text(t('add_employee'), style: const TextStyle(fontWeight: FontWeight.w800)),
          onPressed: () async {
            final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => const EmployeeFormPage()));
            if (ok == true) setState(() => _k = UniqueKey());
          },
        )),
    ]);
  }
}

/// Profile with sections: info · attendance · requests · KPI · evaluations (each loads from its own endpoint).
class EmployeeProfilePage extends StatefulWidget {
  final String id;
  const EmployeeProfilePage({super.key, required this.id});
  @override
  State<EmployeeProfilePage> createState() => _EmployeeProfilePageState();
}

class _EmployeeProfilePageState extends State<EmployeeProfilePage> {
  String _tab = 'profile';
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final isSelf = widget.id == s.id;
    return GlassPage(
      title: isSelf ? t('my_profile') : t('employee_profile'),
      body: AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/employees/${widget.id}'),
        builder: (ctx, d, reload) {
          final e = d.obj('employee')!;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassCard(child: Row(children: [
              GestureDetector(
                onTap: (isSelf || s.has('employee.manage')) ? () => _changePhoto(context, e.s('id'), reload) : null,
                child: Stack(children: [
                  EmployeeAvatar(key: ValueKey('av-${e['updated_at']}'), employeeId: e.s('id'), hasPhoto: e['has_photo'] == true, size: 72),
                  if (isSelf || s.has('employee.manage'))
                    const PositionedDirectional(bottom: 0, end: 0, child: CircleAvatar(radius: 12, backgroundColor: AppColors.primary, child: Icon(Icons.camera_alt, size: 14, color: Colors.white))),
                ]),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(e.s('full_name'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                Text('${e.s('code')} · ${e.s('job_title')}'),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: [
                  StatusChip(I18n.lang == 'ar' ? e.s('role_name_ar') : e.s('role_name_en'), color: AppColors.primary),
                  if (e['status'] == 'inactive') StatusChip(t('inactive'), color: Colors.grey),
                ]),
              ])),
              if (s.has('employee.manage') && !isSelf)
                IconButton(tooltip: t('edit'), icon: const Icon(Icons.edit_rounded), onPressed: () async {
                  final ok = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => EmployeeFormPage(existing: e)));
                  if (ok == true) setState(() => _k = UniqueKey());
                }),
            ])),
            const SizedBox(height: 12),
            FilterChips<String>(options: [
              ('profile', t('profile')), ('attendance', t('attendance')), ('requests', t('requests')),
              ('kpi', t('kpi')), ('evaluations', t('evaluations')),
              if (s.has('employee.read_all') || s.has('audit.read')) ('history', t('history')),
            ], value: _tab, onChanged: (v) => setState(() => _tab = v)),
            const SizedBox(height: 8),
            switch (_tab) {
              'attendance' => AttendanceMonthView(employeeId: e.s('id')),
              'requests' => Padding(padding: const EdgeInsets.only(top: 8), child: RequestList(query: isSelf ? const {'scope': 'mine'} : const {}, employeeId: isSelf ? null : e.s('id'))),
              'kpi' => EmployeeKpiView(employeeId: e.s('id')),
              'evaluations' => EvaluationsView(employeeId: e.s('id'), employeeName: e.s('full_name')),
              'history' => _History(id: e.s('id')),
              _ => _info(context, s, e, isSelf, reload),
            },
          ]);
        },
      ),
    );
  }

  Widget _info(BuildContext context, Session s, Map<String, dynamic> e, bool isSelf, Future<void> Function() reload) {
    final salary = e.obj('salary');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GlassCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(children: [
        InfoTile(title: t('department'), value: e['department_name']?.toString() ?? '—'),
        InfoTile(title: t('team'), value: e['team_name']?.toString() ?? '—'),
        InfoTile(title: t('sales_manager'), value: e['sales_manager_name']?.toString() ?? '—'),
        InfoTile(title: t('joining_date'), value: Fmt.date(e['joining_date'])),
        if (e.containsKey('phone')) InfoTile(title: t('phone'), value: e['phone']?.toString() ?? '—'),
        if (e.containsKey('email')) InfoTile(title: t('email'), value: e['email']?.toString() ?? '—'),
        if (e.containsKey('address')) InfoTile(title: t('address'), value: e['address']?.toString() ?? '—'),
        if (e.containsKey('schedule_name')) InfoTile(title: t('work_schedule'), value: e['schedule_name']?.toString() ?? t('default_schedule')),
        if (e.containsKey('emergency_contact_name')) InfoTile(title: t('emergency_contact'), value: '${e['emergency_contact_name'] ?? '—'} ${e['emergency_contact_phone'] ?? ''}'),
        if (e['notes'] != null && !isSelf) InfoTile(title: t('notes'), value: e.s('notes')),
      ])),
      if (salary != null || (s.has('employee.salary_read') && !isSelf)) ...[
        SectionTitle(t('salary_information')),
        GlassCard(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), child: Column(children: [
          InfoTile(title: t('base_salary'), value: salary == null ? t('not_set') : Fmt.egp(salary['base_salary'])),
          if (s.has('employee.salary_manage') && !isSelf)
            Align(alignment: AlignmentDirectional.centerEnd, child: TextButton.icon(icon: const Icon(Icons.edit), label: Text(t('edit')),
                onPressed: () => _editSalary(context, salary?['base_salary'], reload))),
        ])),
      ],
      if (isSelf) ...[
        const SizedBox(height: 12),
        PrimaryButton(label: t('edit_contact_info'), icon: Icons.contact_phone_rounded, onTap: () => _editContact(context, e, reload)),
      ],
      if (s.has('employee.manage') && !isSelf) ...[
        SectionTitle(t('account')),
        GlassCard(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), child: Column(children: [
          SettingTile(icon: Icons.key_rounded, title: t('reset_password'), onTap: () => _resetPassword(context, e)),
          if (s.allowPin && (e['role_key'] == 'sales_employee' || e['role_key'] == 'sales_manager'))
            SettingTile(icon: Icons.pin_rounded, title: t('new_pin'), onTap: () => _resetPassword(context, e, pin: true)),
          if (e['device_bound'] == true)
            SettingTile(icon: Icons.phonelink_erase_rounded, iconColor: AppColors.warning, title: t('unbind_device'),
                subtitle: '${e['device_label'] ?? ''} · ${Fmt.date(e['device_bound_at'])}', onTap: () => _unbind(context, e, reload))
          else
            SettingTile(icon: Icons.smartphone_rounded, title: t('no_device_bound'), showTrailing: false, onTap: () {}),
          SettingTile(icon: e['status'] == 'active' ? Icons.person_off_rounded : Icons.person_rounded,
              iconColor: e['status'] == 'active' ? AppColors.error : AppColors.success,
              title: e['status'] == 'active' ? t('deactivate') : t('activate'), onTap: () => _toggleStatus(context, e, reload)),
          if (s.has('leave.manage_balances')) SettingTile(icon: Icons.beach_access_rounded, title: t('leave_balance'), onTap: () => _leaveBalance(context, e.s('id'))),
        ])),
      ],
    ]);
  }

  Future<void> _changePhoto(BuildContext context, String id, Future<void> Function() reload) async {
    final s = context.read<Session>();
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 800, imageQuality: 80, preferredCameraDevice: CameraDevice.front)
          .catchError((_) => ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 800, imageQuality: 80));
      if (x == null) return;
      final bytes = await x.readAsBytes();
      await s.api.put('/employees/$id/photo', {'mime': x.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg', 'data': base64Encode(bytes)});
      evictAvatar(id);
      if (id == s.id) await s.refreshMe();
      setState(() => _k = UniqueKey());
    } catch (e) {
      if (context.mounted) showSnack(context, errorText(e), error: true);
    }
  }

  Future<void> _editSalary(BuildContext context, Object? current, Future<void> Function() reload) async {
    final c = TextEditingController(text: current?.toString() ?? '');
    await showGlassSheet(context, title: t('base_salary'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: c, keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: glassInput(context, '${t('base_salary')} (${t('egp')})')),
      const SizedBox(height: 16),
      PrimaryButton(label: t('save'), onTap: () async {
        final v = double.tryParse(c.text.trim());
        if (v == null || v < 0) { showSnack(context, t('invalid_amount'), error: true); return; }
        try {
          await context.read<Session>().api.put('/employees/${widget.id}/salary', {'baseSalary': v});
          if (context.mounted) { Navigator.pop(context); await reload(); }
        } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
      }),
    ]));
  }

  Future<void> _editContact(BuildContext context, Map<String, dynamic> e, Future<void> Function() reload) async {
    final phone = TextEditingController(text: e['phone']?.toString() ?? '');
    final email = TextEditingController(text: e['email']?.toString() ?? '');
    final addr = TextEditingController(text: e['address']?.toString() ?? '');
    final ecn = TextEditingController(text: e['emergency_contact_name']?.toString() ?? '');
    final ecp = TextEditingController(text: e['emergency_contact_phone']?.toString() ?? '');
    await showGlassSheet(context, title: t('edit_contact_info'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: phone, keyboardType: TextInputType.phone, decoration: glassInput(context, t('phone'))),
      const SizedBox(height: 10),
      TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: glassInput(context, t('email'))),
      const SizedBox(height: 10),
      TextField(controller: addr, decoration: glassInput(context, t('address'))),
      const SizedBox(height: 10),
      TextField(controller: ecn, decoration: glassInput(context, t('emergency_contact_name'))),
      const SizedBox(height: 10),
      TextField(controller: ecp, keyboardType: TextInputType.phone, decoration: glassInput(context, t('emergency_contact_phone'))),
      const SizedBox(height: 16),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          await context.read<Session>().api.patch('/employees/${widget.id}', {
            'phone': phone.text.trim().isEmpty ? null : phone.text.trim(),
            'email': email.text.trim().isEmpty ? null : email.text.trim(),
            'address': addr.text.trim().isEmpty ? null : addr.text.trim(),
            'emergencyContactName': ecn.text.trim().isEmpty ? null : ecn.text.trim(),
            'emergencyContactPhone': ecp.text.trim().isEmpty ? null : ecp.text.trim(),
          });
          if (context.mounted) { Navigator.pop(context); await reload(); }
        } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); }
      }),
    ]));
  }

  Future<void> _resetPassword(BuildContext context, Map<String, dynamic> e, {bool pin = false}) async {
    final ok = await confirmDialog(context, title: pin ? t('new_pin') : t('reset_password'),
        message: pin ? t('new_pin_confirm') : t('reset_password_confirm'), ok: t('yes'), cancel: t('no'));
    if (!ok || !context.mounted) return;
    try {
      final r = await context.read<Session>().api.post('/employees/${e['id']}/reset-password', pin ? {'kind': 'pin'} : {});
      if (!context.mounted) return;
      if (pin) {
        await showPinSheet(context, name: e.s('full_name'), phone: e.s('phone'), code: e.s('code'), pin: r.s('pin'));
      } else {
        await showTempPassword(context, e.s('code'), r.s('temporaryPassword'));
      }
    } catch (err) { if (context.mounted) showSnack(context, errorText(err), error: true); }
  }

  Future<void> _unbind(BuildContext context, Map<String, dynamic> e, Future<void> Function() reload) async {
    final ok = await confirmDialog(context, title: t('unbind_device'), message: t('unbind_device_confirm'), ok: t('yes'), cancel: t('no'));
    if (!ok || !context.mounted) return;
    try {
      await context.read<Session>().api.post('/employees/${e['id']}/unbind-device');
      if (context.mounted) showSnack(context, t('device_unbound'));
      await reload();
    } catch (err) { if (context.mounted) showSnack(context, errorText(err), error: true); }
  }

  Future<void> _toggleStatus(BuildContext context, Map<String, dynamic> e, Future<void> Function() reload) async {
    final next = e['status'] == 'active' ? 'inactive' : 'active';
    final ok = await confirmDialog(context, title: next == 'inactive' ? t('deactivate') : t('activate'),
        message: next == 'inactive' ? t('deactivate_confirm') : t('activate_confirm'), ok: t('yes'), cancel: t('no'));
    if (!ok || !context.mounted) return;
    try {
      await context.read<Session>().api.post('/employees/${e['id']}/status', {'status': next});
      setState(() => _k = UniqueKey());
    } catch (err) { if (context.mounted) showSnack(context, errorText(err), error: true); }
  }

  Future<void> _leaveBalance(BuildContext context, String id) async {
    final s = context.read<Session>();
    final year = DateTime.now().year;
    Map<String, dynamic> cur;
    try { cur = await s.api.get('/leave-balances/$id', {'year': '$year'}); } catch (e) { if (context.mounted) showSnack(context, errorText(e), error: true); return; }
    final ent = cur.obj('entitled') ?? {};
    final annual = TextEditingController(text: '${ent['annual_days'] ?? 21}');
    final casual = TextEditingController(text: '${ent['casual_days'] ?? 7}');
    final sick = TextEditingController(text: '${ent['sick_days'] ?? 0}');
    final used = cur.obj('used') ?? {};
    if (!context.mounted) return;
    await showGlassSheet(context, title: '${t('leave_balance')} $year', child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(t('used_days_summary', {'annual': used['annual'] ?? 0, 'casual': used['casual'] ?? 0, 'sick': used['sick'] ?? 0})),
      const SizedBox(height: 12),
      TextField(controller: annual, keyboardType: TextInputType.number, decoration: glassInput(context, t('annual_days'))),
      const SizedBox(height: 10),
      TextField(controller: casual, keyboardType: TextInputType.number, decoration: glassInput(context, t('casual_days'))),
      const SizedBox(height: 10),
      TextField(controller: sick, keyboardType: TextInputType.number, decoration: glassInput(context, t('sick_days'))),
      const SizedBox(height: 16),
      PrimaryButton(label: t('save'), onTap: () async {
        try {
          await s.api.put('/leave-balances/$id', {'year': year, 'annualDays': num.parse(annual.text), 'casualDays': num.parse(casual.text), 'sickDays': num.parse(sick.text)});
          if (context.mounted) { Navigator.pop(context); showSnack(context, t('saved')); }
        } catch (e) { if (context.mounted) showSnack(context, e is FormatException ? t('invalid_amount') : errorText(e), error: true); }
      }),
    ]));
  }
}

class _History extends StatelessWidget {
  final String id;
  const _History({required this.id});
  @override
  Widget build(BuildContext context) => AsyncView<Map<String, dynamic>>(
        load: () => context.read<Session>().api.get('/employees/$id/history'),
        builder: (ctx, d, _) {
          final h = d.list('history');
          if (h.isEmpty) return EmptyState(t('no_history'));
          return GlassCard(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: Column(children: [
            for (final x in h) ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.history_rounded),
              title: Text(t('audit_${x.s('action').replaceAll('.', '_')}'), style: const TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('${x['actor_name'] ?? '—'} · ${Fmt.dateTime(x['at'])}'),
            ),
          ]));
        },
      );
}

/// Value HR: show the PIN once and let HR copy a ready WhatsApp message for the employee.
Future<void> showPinSheet(BuildContext context, {required String name, required String phone, required String code, required String pin}) {
  final company = context.read<Session>().company;
  final companyName = I18n.lang == 'ar' ? (company?['company_name_ar'] ?? '') : (company?['company_name_en'] ?? '');
  final msg = t('pin_whatsapp_message', {'name': name, 'company': companyName, 'phone': phone.isEmpty ? code : phone, 'pin': pin,
      'url': 'https://peterbakheetuae-svg.github.io/value-attendance/'});
  return showGlassSheet(context, title: t('new_pin'), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Text(t('pin_shown_once')),
    const SizedBox(height: 12),
    InfoTile(title: t('phone_or_code'), value: phone.isEmpty ? code : phone),
    InfoTile(title: t('pin'), value: pin),
    const SizedBox(height: 12),
    PrimaryButton(label: t('copy_whatsapp_message'), icon: Icons.chat_rounded, onTap: () async {
      await Clipboard.setData(ClipboardData(text: msg));
      if (context.mounted) showSnack(context, t('copied_paste_whatsapp'));
    }),
  ]));
}

Future<void> showTempPassword(BuildContext context, String code, String pw) => showGlassSheet(context, title: t('temporary_password'), child: Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    Text(t('temporary_password_note')),
    const SizedBox(height: 12),
    InfoTile(title: t('employee_code'), value: code),
    InfoTile(title: t('password'), value: pw),
    const SizedBox(height: 12),
    PrimaryButton(label: t('copy'), icon: Icons.copy, onTap: () async {
      await Clipboard.setData(ClipboardData(text: '${t('employee_code')}: $code\n${t('password')}: $pw'));
      if (context.mounted) showSnack(context, t('copied'));
    }),
  ],
));

/// Add / edit employee (HR & owner). Role options respect what the server lets this user assign.
class EmployeeFormPage extends StatefulWidget {
  final Map<String, dynamic>? existing;
  const EmployeeFormPage({super.key, this.existing});
  @override
  State<EmployeeFormPage> createState() => _EmployeeFormPageState();
}

class _EmployeeFormPageState extends State<EmployeeFormPage> {
  late final Map<String, TextEditingController> c;
  String _role = 'sales_employee';
  bool _usePin = true;
  String? _dept, _team, _manager, _schedule;
  DateTime? _joining;
  bool _busy = false;
  late Future<List<Map<String, dynamic>>> _refs;

  bool get editing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing ?? {};
    c = {for (final k in ['code', 'full_name', 'phone', 'email', 'address', 'job_title', 'emergency_contact_name', 'emergency_contact_phone', 'notes', 'salary'])
      k: TextEditingController(text: e[k]?.toString() ?? '')};
    _role = e['role_key']?.toString() ?? 'sales_employee';
    _dept = e['department_id']?.toString();
    _team = e['team_id']?.toString();
    _manager = e['sales_manager_id']?.toString();
    _schedule = e['schedule_id']?.toString();
    _joining = e['joining_date'] == null ? null : DateTime.tryParse(e['joining_date'].toString());
    final api = context.read<Session>().api;
    _refs = Future.wait([
      api.get('/departments').then((r) => r),
      api.get('/teams').then((r) => r),
      api.get('/employees', {'role': 'sales_manager'}).then((r) => r),
      api.get('/schedules').then((r) => r),
    ]);
  }

  @override
  void dispose() { for (final x in c.values) { x.dispose(); } super.dispose(); }

  String? _v(String k) => c[k]!.text.trim().isEmpty ? null : c[k]!.text.trim();

  Future<void> _save() async {
    final s = context.read<Session>();
    if ((!editing && _v('code') == null) || _v('full_name') == null) { showSnack(context, t('fill_required'), error: true); return; }
    final body = <String, dynamic>{
      'fullName': _v('full_name'), 'phone': _v('phone'), 'email': _v('email'), 'address': _v('address'),
      'jobTitle': _v('job_title') ?? '', 'emergencyContactName': _v('emergency_contact_name'),
      'emergencyContactPhone': _v('emergency_contact_phone'), 'notes': _v('notes'),
      'departmentId': _dept, 'teamId': _team, 'salesManagerId': _manager, 'scheduleId': _schedule,
      if (_joining != null) 'joiningDate': ymd(_joining!),
    };
    setState(() => _busy = true);
    try {
      if (editing) {
        if (_role != widget.existing!['role_key']) body['role'] = _role;
        await s.api.patch('/employees/${widget.existing!['id']}', body);
        if (mounted) Navigator.pop(context, true);
      } else {
        body['code'] = _v('code')!.toUpperCase();
        body['role'] = _role;
        body.removeWhere((k, v) => v == null);
        final sal = double.tryParse(c['salary']!.text.trim());
        if (sal != null && s.has('employee.salary_manage')) body['baseSalary'] = sal;
        final usePin = _usePin && s.allowPin && (_role == 'sales_employee' || _role == 'sales_manager');
        if (usePin) body['loginKind'] = 'pin';
        final r = await s.api.post('/employees', body);
        if (!mounted) return;
        if (usePin) {
          await showPinSheet(context, name: _v('full_name') ?? '', phone: _v('phone') ?? '', code: r.s('code'), pin: r.s('pin'));
        } else {
          await showTempPassword(context, r.s('code'), r.s('temporaryPassword'));
        }
        if (mounted) Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(String k, String label, {TextInputType? type, int lines = 1}) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(controller: c[k], keyboardType: type, maxLines: lines, decoration: glassInput(context, label)),
      );

  Widget _drop(String label, String? value, List<(String, String)> items, ValueChanged<String?> onChanged) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: DropdownButtonFormField<String?>(
          value: items.any((x) => x.$1 == value) ? value : null,
          isExpanded: true,
          decoration: glassInput(context, label),
          items: [DropdownMenuItem<String?>(value: null, child: Text(t('none'))), for (final x in items) DropdownMenuItem<String?>(value: x.$1, child: Text(x.$2))],
          onChanged: onChanged,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final roles = <String>['sales_employee', 'sales_manager', if (s.has('roles.manage')) ...['accountant', 'hr_manager', 'owner']];
    return GlassPage(
      title: editing ? t('edit_employee') : t('add_employee'),
      body: FutureBuilder<List<Map<String, dynamic>>>(
        future: _refs,
        builder: (ctx, snap) {
          if (!snap.hasData) return snap.hasError ? ErrorState(errorText(snap.error!)) : const LoadingState();
          final deps = snap.data![0].list('departments').where((x) => x['active'] == true).map((x) => (x.s('id'), x.s('name_ar'))).toList();
          final teams = snap.data![1].list('teams').where((x) => x['active'] == true).map((x) => (x.s('id'), x.s('name'))).toList();
          final mgrs = snap.data![2].list('employees').where((x) => x['role_key'] == 'sales_manager' && x['id'] != widget.existing?['id']).map((x) => (x.s('id'), x.s('full_name'))).toList();
          final sch = snap.data![3].list('schedules').map((x) => (x.s('id'), x.s('name'))).toList();
          return GlassCard(radius: 20, child: Material(type: MaterialType.transparency, child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (!editing) _field('code', '${t('employee_code')} *'),
            _field('full_name', '${t('full_name')} *'),
            _field('job_title', t('job_title')),
            Padding(padding: const EdgeInsets.only(bottom: 12), child: DropdownButtonFormField<String>(
              value: roles.contains(_role) ? _role : null,
              decoration: glassInput(context, t('role')),
              items: [for (final r in roles) DropdownMenuItem(value: r, child: Text(t('role_$r')))],
              onChanged: (editing && widget.existing!['id'] == s.id) ? null : (v) => setState(() => _role = v ?? _role),
            )),
            if (!editing && s.allowPin && (_role == 'sales_employee' || _role == 'sales_manager'))
              SwitchListTile(contentPadding: EdgeInsets.zero, value: _usePin, title: Text(t('login_with_pin')), subtitle: Text(t('login_with_pin_help')),
                  onChanged: (v) => setState(() => _usePin = v)),
            _drop(t('department'), _dept, deps, (v) => setState(() => _dept = v)),
            _drop(t('team'), _team, teams, (v) => setState(() => _team = v)),
            _drop(t('sales_manager'), _manager, mgrs, (v) => setState(() => _manager = v)),
            _drop(t('work_schedule'), _schedule, sch, (v) => setState(() => _schedule = v)),
            Padding(padding: const EdgeInsets.only(bottom: 12), child: OutlinedButton.icon(
              icon: const Icon(Icons.event), label: Text(_joining == null ? t('joining_date') : '${t('joining_date')}: ${Fmt.date(ymd(_joining!))}'),
              onPressed: () async { final d = await pickDate(context, initial: _joining, first: DateTime(2000)); if (d != null) setState(() => _joining = d); },
            )),
            _field('phone', t('phone'), type: TextInputType.phone),
            _field('email', t('email'), type: TextInputType.emailAddress),
            _field('address', t('address')),
            _field('emergency_contact_name', t('emergency_contact_name')),
            _field('emergency_contact_phone', t('emergency_contact_phone'), type: TextInputType.phone),
            _field('notes', t('notes'), lines: 3),
            if (!editing && s.has('employee.salary_manage')) _field('salary', '${t('base_salary')} (${t('egp')})', type: const TextInputType.numberWithOptions(decimal: true)),
            const SizedBox(height: 4),
            PrimaryButton(label: t('save'), loading: _busy, onTap: _save),
          ])));
        },
      ),
    );
  }
}
