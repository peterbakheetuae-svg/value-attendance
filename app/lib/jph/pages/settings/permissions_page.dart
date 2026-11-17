import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/glass_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// «إعدادات الشركة ← الصلاحيات»: the one place permissions are managed — job-title profiles, individual exceptions,
/// comparing two profiles and the change history. Everything here is enforced by the server too (it refuses changing
/// your own permissions, granting what you do not hold, and taking the last «إدارة الصلاحيات» away).
class PermissionsPage extends StatefulWidget {
  const PermissionsPage({super.key});
  static bool get canOpen => ApiService.can('roles.manage');

  @override
  State<PermissionsPage> createState() => _PermissionsPageState();
}

Future<Map<String, dynamic>> _get(String path, [Map<String, String?>? q]) =>
    ApiService.post({'action': 'cash_get', 'path': path, if (q != null) 'query': q});
Future<Map<String, dynamic>> _put(String path, Map<String, dynamic> body, {String ok = 'اتحفظ ✅', bool post = false}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok, if (!post) 'method': 'put'});

class _Perm {
  final String key, module, name, desc;
  final bool sensitive, available, delegable;
  _Perm(Map m)
      : key = '${m['key']}',
        module = '${m['module']}',
        name = '${m['nameAr']}',
        desc = '${m['descAr'] ?? ''}',
        sensitive = m['sensitive'] == true,
        available = m['available'] == true,
        delegable = m['delegable'] == true;
}

class _PermissionsPageState extends State<PermissionsPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 4, vsync: this);
  bool _loading = true;
  String _error = '';
  List<Map<String, dynamic>> _modules = [];
  List<_Perm> _perms = [];
  List<Map<String, dynamic>> _roles = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final reg = await _get('/permissions/registry');
    final roles = await _get('/permissions/roles');
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (reg['success'] != true || roles['success'] != true) {
        _error = '${reg['message'] ?? roles['message'] ?? ''}';
        return;
      }
      _error = '';
      _modules = ((reg['modules'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      // only keys this database has (a key waiting for its migration is not offered)
      _perms = ((reg['permissions'] as List?) ?? const []).whereType<Map>().map(_Perm.new).where((p) => p.available).toList();
      _roles = ((roles['roles'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  String _moduleName(String k) => '${_modules.firstWhere((m) => m['key'] == k, orElse: () => {'nameAr': k})['nameAr']}';

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('الصلاحيات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
          actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
          bottom: TabBar(controller: _tabs, isScrollable: true, labelColor: AppColors.primary, tabs: [
            Tab(text: txs('المسميات الوظيفية')),
            Tab(text: txs('الموظفين')),
            Tab(text: txs('مقارنة')),
            Tab(text: txs('سجل التغييرات')),
          ]),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error.isNotEmpty
                ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error, textAlign: TextAlign.center)))
                : TabBarView(controller: _tabs, children: [
                    _RolesTab(state: this),
                    _EmployeesTab(state: this),
                    _CompareTab(state: this),
                    const _AuditTab(),
                  ]),
      ),
    );
  }

  void snack(Map<String, dynamic> r) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Ar.green : Ar.red));
  }

  /// sensitive permissions are confirmed before anything is sent
  Future<bool> confirmSensitive(List<_Perm> changed, String what) async {
    final s = changed.where((p) => p.sensitive).toList();
    if (s.isEmpty) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('تأكيد تغيير صلاحيات حساسة'),
        content: Text('$what\n\n${s.map((p) => '• ${p.name}').join('\n')}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
          ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('تأكيد')),
        ],
      ),
    );
    return ok == true;
  }

  /// grouped, searchable list of permissions (one ExpansionTile per module)
  Widget matrix({
    required String query,
    required Widget Function(_Perm p) row,
    Widget Function(String module, List<_Perm> perms)? groupAction,
  }) {
    final q = query.trim();
    final byModule = <String, List<_Perm>>{};
    for (final p in _perms) {
      if (q.isNotEmpty && !p.name.contains(q) && !p.key.contains(q) && !_moduleName(p.module).contains(q) && !p.desc.contains(q)) continue;
      byModule.putIfAbsent(p.module, () => []).add(p);
    }
    final order = _modules.map((m) => '${m['key']}').toList();
    final keys = byModule.keys.toList()..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    return Column(children: [
      for (final m in keys)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: q.isNotEmpty,
                tilePadding: EdgeInsets.zero,
                title: Text(_moduleName(m), style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text('${byModule[m]!.length} صلاحية', style: const TextStyle(fontSize: 12)),
                children: [
                  if (groupAction != null) groupAction(m, byModule[m]!),
                  ...byModule[m]!.map(row),
                ],
              ),
            ),
          ),
        ),
    ]);
  }
}

InputDecoration _search(String hint) => InputDecoration(
    prefixIcon: const Icon(Icons.search), hintText: txs(hint), isDense: true,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)));

Widget _permTitle(_Perm p) => Row(children: [
      Flexible(child: Text(p.name)),
      if (p.sensitive) const Padding(padding: EdgeInsetsDirectional.only(start: 6), child: Icon(Icons.shield_outlined, size: 15, color: Ar.amber)),
    ]);

// ------------------------------------------------------------------------------------------------ job-title profiles
class _RolesTab extends StatelessWidget {
  final _PermissionsPageState state;
  const _RolesTab({required this.state});

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
      const Text('كل مسمى وظيفي له مجموعة صلاحيات؛ أي تغيير فيها بيسري على كل موظفيه من الطلب اللي بعده. '
          'المالك عنده كل الصلاحيات دايمًا (مسار الاسترداد)، ومش ممكن تعدّل صلاحيات مسماك أنت.',
          style: TextStyle(fontSize: 12)),
      const SizedBox(height: 10),
      for (final r in state._roles)
        Card(
          color: isDark ? Colors.white10 : Colors.white,
          child: ListTile(
            leading: Icon(r['builtin'] == true ? Icons.verified_user_rounded : Icons.work_outline_rounded,
                color: r['active'] == false ? Ar.grey : AppColors.primary),
            title: Text('${r['nameAr']}', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text([
              if (r['baseNameAr'] != null) 'تتبع: ${r['baseNameAr']}',
              '${r['employees']} موظف',
              '${(r['perms'] as List).length} صلاحية',
              if (r['lockedReason'] == 'owner') 'ثابتة',
              if (r['lockedReason'] == 'own_profile') 'مسماك (للعرض بس)',
            ].join(' • ')),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _RoleEditor(state: state, role: r))),
          ),
        ),
    ]);
  }
}

class _RoleEditor extends StatefulWidget {
  final _PermissionsPageState state;
  final Map<String, dynamic> role;
  const _RoleEditor({required this.state, required this.role});
  @override
  State<_RoleEditor> createState() => _RoleEditorState();
}

class _RoleEditorState extends State<_RoleEditor> {
  late Set<String> _orig = ((widget.role['perms'] as List?) ?? const []).map((e) => '$e').toSet();
  late Set<String> _next = {..._orig};
  bool _editing = false, _saving = false;
  String _q = '';

  bool get _editable => widget.role['editable'] == true;

  Future<void> _save() async {
    final grant = _next.difference(_orig).toList(), revoke = _orig.difference(_next).toList();
    if (grant.isEmpty && revoke.isEmpty) return setState(() => _editing = false);
    final changed = widget.state._perms.where((p) => grant.contains(p.key) || revoke.contains(p.key)).toList();
    if (!await widget.state.confirmSensitive(changed, 'هتتغير صلاحيات «${widget.role['nameAr']}» لكل موظفيه (${widget.role['employees']}):')) return;
    setState(() => _saving = true);
    final r = await _put('/permissions/roles/${widget.role['key']}', {'grant': grant, 'revoke': revoke, 'confirm': true});
    if (!mounted) return;
    setState(() => _saving = false);
    widget.state.snack(r);
    if (r['success'] == true) {
      setState(() { _orig = {..._next}; _editing = false; });
      widget.state._load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent, elevation: 0,
          title: Text('${widget.role['nameAr']}'),
          actions: [
            if (_editable && !_editing) TextButton.icon(onPressed: () => setState(() => _editing = true), icon: const Icon(Icons.edit_outlined), label: const Text('تعديل')),
            if (_editing) TextButton(onPressed: () => setState(() { _next = {..._orig}; _editing = false; }), child: const Text('إلغاء')),
            if (_editing) TextButton(onPressed: _saving ? null : _save, child: const Text('حفظ')),
          ],
        ),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
          if (!_editable)
            Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(
                widget.role['lockedReason'] == 'owner' ? 'صلاحيات المالك ثابتة: عنده كل الصلاحيات دايمًا.' : 'ده مسماك الوظيفي: مش ممكن تعدّل صلاحياتك بنفسك.',
                style: const TextStyle(color: Ar.amber))),
          TextField(decoration: _search('ابحث باسم الصلاحية أو القسم'), onChanged: (v) => setState(() => _q = v)),
          const SizedBox(height: 10),
          s.matrix(
            query: _q,
            groupAction: !_editing ? null : (m, perms) {
              final mine = perms.where((p) => p.delegable).toList();
              final all = mine.every((p) => _next.contains(p.key));
              return Align(alignment: AlignmentDirectional.centerEnd, child: TextButton(
                onPressed: () => setState(() => all ? _next.removeAll(mine.map((p) => p.key)) : _next.addAll(mine.map((p) => p.key))),
                child: Text(all ? 'إلغاء كل القسم' : 'تحديد كل القسم'),
              ));
            },
            row: (p) => CheckboxListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              value: _next.contains(p.key),
              title: _permTitle(p),
              subtitle: Text(p.desc + (p.delegable ? '' : ' — مش معاك، فمش ممكن تديها'), style: const TextStyle(fontSize: 11)),
              onChanged: !_editing || !p.delegable ? null : (v) => setState(() => v == true ? _next.add(p.key) : _next.remove(p.key)),
            ),
          ),
        ]),
      ),
    );
  }
}

// ------------------------------------------------------------------------------------------------ individual employees
class _EmployeesTab extends StatefulWidget {
  final _PermissionsPageState state;
  const _EmployeesTab({required this.state});
  @override
  State<_EmployeesTab> createState() => _EmployeesTabState();
}

class _EmployeesTabState extends State<_EmployeesTab> {
  List<Map<String, dynamic>> _list = [];
  bool _loading = true;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/permissions/employees', {'q': _q});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _list = ((r['employees'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
      TextField(decoration: _search('ابحث باسم الموظف أو كوده'), onChanged: (v) { _q = v; _load(); }),
      const SizedBox(height: 10),
      if (_loading) const Center(child: CircularProgressIndicator()),
      for (final e in _list)
        ListTile(
          title: Text('${e['name']}'),
          subtitle: Text([
            '${e['roleName']}',
            if ((e['granted'] ?? 0) > 0) '+${e['granted']} ممنوحة',
            if ((e['denied'] ?? 0) > 0) '−${e['denied']} ممنوعة',
          ].join(' • ')),
          trailing: const Icon(Icons.chevron_left_rounded),
          onTap: () async {
            await Navigator.push(context, MaterialPageRoute(builder: (_) => _EmployeeEditor(state: widget.state, id: '${e['id']}')));
            _load();
          },
        ),
    ]);
  }
}

class _EmployeeEditor extends StatefulWidget {
  final _PermissionsPageState state;
  final String id;
  const _EmployeeEditor({required this.state, required this.id});
  @override
  State<_EmployeeEditor> createState() => _EmployeeEditorState();
}

class _EmployeeEditorState extends State<_EmployeeEditor> {
  Map<String, dynamic>? _d;
  String _q = '';
  bool _onlyEffective = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/permissions/employees/${widget.id}');
    if (mounted) setState(() => _d = r['success'] == true ? r : {'error': r['message']});
  }

  Future<void> _set(_Perm p, String value) async {
    if (!await widget.state.confirmSensitive([p], 'تغيير صلاحية حساسة لـ ${_d?['employee']?['name']}:')) return;
    final r = await _put('/permissions/employees/${widget.id}', {'perm': p.key, 'value': value, 'confirm': true});
    widget.state.snack(r);
    _load();
  }

  Future<void> _reset() async {
    final ov = ((_d?['overrides'] as Map?) ?? const {}).keys.map((k) => '$k').toSet();
    if (ov.isEmpty) return;
    final changed = widget.state._perms.where((p) => ov.contains(p.key)).toList();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('رجوع لصلاحيات المسمى'),
      content: Text('هيتشال ${ov.length} استثناء فردي، والموظف يرجع لصلاحيات مسماه بالظبط.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
        ElevatedButton(onPressed: () => Navigator.pop(c, true), child: const Text('تأكيد')),
      ],
    ));
    if (ok != true) return;
    final r = await _put('/permissions/employees/${widget.id}/reset', {'confirm': changed.isNotEmpty}, ok: 'رجع لصلاحيات المسمى ✅', post: true);
    widget.state.snack(r);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    final emp = (d?['employee'] as Map?) ?? const {};
    final inherited = ((d?['inherited'] as List?) ?? const []).map((e) => '$e').toSet();
    final effective = ((d?['effective'] as List?) ?? const []).map((e) => '$e').toSet();
    final ov = ((d?['overrides'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', '$v'));
    final editable = d?['editable'] == true;
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent, elevation: 0,
          title: Text('${emp['name'] ?? ''}'),
          actions: [if (editable && ov.isNotEmpty) TextButton(onPressed: _reset, child: const Text('رجوع للمسمى'))],
        ),
        body: d == null
            ? const Center(child: CircularProgressIndicator())
            : d['error'] != null
                ? Center(child: Text('${d['error']}'))
                : ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
                    Text('المسمى: ${emp['roleName']} • ${effective.length} صلاحية فعلية • ${ov.length} استثناء فردي'),
                    if (!editable)
                      Padding(padding: const EdgeInsets.only(top: 6), child: Text(
                          d['lockedReason'] == 'self' ? 'دي صلاحياتك: مش ممكن تعدّلها بنفسك.' : 'حساب المالك عنده كل الصلاحيات دايمًا (مسار الاسترداد).',
                          style: const TextStyle(color: Ar.amber))),
                    const SizedBox(height: 6),
                    const Wrap(spacing: 10, children: [
                      _Legend(color: AppColors.primary, text: 'موروث من المسمى'),
                      _Legend(color: Ar.green, text: 'ممنوح فرديًا'),
                      _Legend(color: Ar.red, text: 'ممنوع فرديًا'),
                    ]),
                    const SizedBox(height: 8),
                    TextField(decoration: _search('ابحث باسم الصلاحية أو القسم'), onChanged: (v) => setState(() => _q = v)),
                    SwitchListTile(contentPadding: EdgeInsets.zero, value: _onlyEffective, title: const Text('اعرض الصلاحيات الفعلية بس'),
                        onChanged: (v) => setState(() => _onlyEffective = v)),
                    widget.state.matrix(
                      query: _q,
                      row: (p) {
                        if (_onlyEffective && !effective.contains(p.key)) return const SizedBox.shrink();
                        final o = ov[p.key];
                        final on = effective.contains(p.key);
                        final color = o == 'allow' ? Ar.green : o == 'deny' ? Ar.red : on ? AppColors.primary : Ar.grey;
                        final src = o == 'allow' ? 'ممنوح فرديًا' : o == 'deny' ? 'ممنوع فرديًا' : inherited.contains(p.key) ? 'موروث من المسمى' : 'مش ممنوح';
                        return ListTile(
                          dense: true, contentPadding: EdgeInsets.zero,
                          leading: Icon(on ? Icons.check_circle_rounded : Icons.block_rounded, color: color, size: 20),
                          title: _permTitle(p),
                          subtitle: Text(src, style: TextStyle(fontSize: 11, color: color)),
                          trailing: !editable || !p.delegable
                              ? null
                              : DropdownButton<String>(
                                  value: o ?? 'inherit',
                                  underline: const SizedBox.shrink(),
                                  items: const [
                                    DropdownMenuItem(value: 'inherit', child: Text('حسب المسمى')),
                                    DropdownMenuItem(value: 'allow', child: Text('سماح')),
                                    DropdownMenuItem(value: 'deny', child: Text('منع')),
                                  ],
                                  onChanged: (v) { if (v != null && v != (o ?? 'inherit')) _set(p, v); },
                                ),
                        );
                      },
                    ),
                  ]),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  final Color color;
  final String text;
  const _Legend({required this.color, required this.text});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.circle, size: 10, color: color), const SizedBox(width: 4), Text(text, style: const TextStyle(fontSize: 11)),
      ]);
}

// ------------------------------------------------------------------------------------------------ compare two profiles
class _CompareTab extends StatefulWidget {
  final _PermissionsPageState state;
  const _CompareTab({required this.state});
  @override
  State<_CompareTab> createState() => _CompareTabState();
}

class _CompareTabState extends State<_CompareTab> {
  String? _a, _b;

  @override
  Widget build(BuildContext context) {
    final roles = widget.state._roles;
    Set<String> permsOf(String? k) => ((roles.firstWhere((r) => r['key'] == k, orElse: () => {'perms': []})['perms'] as List?) ?? const [])
        .map((e) => '$e').toSet();
    final pa = permsOf(_a), pb = permsOf(_b);
    DropdownButtonFormField<String> pick(String? v, ValueChanged<String?> on, String label) => DropdownButtonFormField<String>(
          value: v, isExpanded: true,
          decoration: InputDecoration(labelText: txs(label), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)), isDense: true),
          items: roles.map((r) => DropdownMenuItem(value: '${r['key']}', child: Text('${r['nameAr']}'))).toList(),
          onChanged: on,
        );
    return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
      pick(_a, (v) => setState(() => _a = v), 'المسمى الأول'),
      const SizedBox(height: 10),
      pick(_b, (v) => setState(() => _b = v), 'المسمى التاني'),
      const SizedBox(height: 12),
      if (_a != null && _b != null) ...[
        Text('مشتركة: ${pa.intersection(pb).length} • في الأول بس: ${pa.difference(pb).length} • في التاني بس: ${pb.difference(pa).length}'),
        const SizedBox(height: 8),
        widget.state.matrix(
          query: '',
          row: (p) {
            final ia = pa.contains(p.key), ib = pb.contains(p.key);
            if (ia == ib) return const SizedBox.shrink();
            return ListTile(
              dense: true, contentPadding: EdgeInsets.zero,
              title: _permTitle(p),
              trailing: Text(ia ? 'الأول بس' : 'التاني بس', style: TextStyle(color: ia ? AppColors.primary : Ar.amber)),
            );
          },
        ),
      ],
    ]);
  }
}

// ------------------------------------------------------------------------------------------------ change history
class _AuditTab extends StatefulWidget {
  const _AuditTab();
  @override
  State<_AuditTab> createState() => _AuditTabState();
}

class _AuditTabState extends State<_AuditTab> {
  List<Map<String, dynamic>>? _rows;

  @override
  void initState() {
    super.initState();
    _get('/permissions/audit').then((r) {
      if (mounted) setState(() => _rows = ((r['entries'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList());
    });
  }

  String _v(dynamic x) {
    final v = x is Map ? '${x['value'] ?? ''}' : '';
    return const {'on': 'ممنوحة', 'off': 'مش ممنوحة', 'allow': 'سماح', 'deny': 'منع', 'inherit': 'حسب المسمى'}[v] ?? v;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    if (rows == null) return const Center(child: CircularProgressIndicator());
    if (rows.isEmpty) return const Center(child: Text('مفيش تغييرات لسه'));
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, i) {
        final r = rows[i];
        final after = r['after'];
        final perm = after is Map ? '${after['perm'] ?? ''}' : '';
        final at = DateTime.tryParse('${r['at']}')?.toLocal();
        return ListTile(
          dense: true,
          title: Text('${r['targetName'] ?? r['entityId']} — ${perm.isEmpty ? r['action'] : perm}'),
          subtitle: Text([
            if (perm.isNotEmpty) '${_v(r['before'])} ← ${_v(after)}',
            'بواسطة ${r['actorName'] ?? '—'}',
            if (at != null) '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')} ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}',
          ].join(' • ')),
        );
      },
    );
  }
}
