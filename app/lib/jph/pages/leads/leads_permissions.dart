import 'package:flutter/material.dart';

import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import 'leads_api.dart';

/// الإعدادات / التحكم في الوصول / صلاحيات الأدوار (like Elite): what every role may do on the sales board, then
/// exceptions for one employee (allowed / denied on top of his role). The owner only; the owner role always has all.
class LeadsPermissionsView extends StatefulWidget {
  final bool isDark;
  const LeadsPermissionsView({super.key, required this.isDark});

  @override
  State<LeadsPermissionsView> createState() => _LeadsPermissionsViewState();
}

class _LeadsPermissionsViewState extends State<LeadsPermissionsView> {
  Map<String, dynamic> _d = {};
  bool _loading = true;
  String? _emp;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await lget('/leads/permissions');
    if (!mounted) return;
    setState(() {
      _loading = false;
      _d = r;
    });
  }

  bool get isDark => widget.isDark;

  Future<void> _setRole(String role, String perm, bool on) async {
    final k = '$role/$perm';
    if (_busy.contains(k)) return;
    setState(() {
      _busy.add(k);
      for (final r in ll(_d['roles'])) {
        if (r['key'] == role) {
          final p = List<String>.from((r['perms'] as List?) ?? const []);
          on ? p.add(perm) : p.remove(perm);
          r['perms'] = p;
        }
      }
    });
    final r = await lpost('/leads/permissions/role', {'role': role, 'perm': perm, 'on': on}, method: 'put');
    if (!mounted) return;
    setState(() => _busy.remove(k));
    if (r['success'] != true) {
      JphUi.toast(context, r);
      _load();
    }
  }

  Future<void> _setEmp(String id, String perm, String value) async {
    final r = await lpost('/leads/permissions/employee', {'employeeId': id, 'perm': perm, 'value': value}, method: 'put', ok: tr('اتحفظ ✅'));
    if (!mounted) return;
    JphUi.toast(context, r);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator()));
    if (_d['success'] == false) return Text('${_d['message']}', style: TextStyle(color: JphUi.sub(isDark)));
    final perms = ll(_d['perms']);
    final roles = ll(_d['roles']);
    final emps = ll(_d['employees']);
    final emp = emps.where((e) => e['id'] == _emp).firstOrNull;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(tr('الإعدادات / التحكم في الوصول'), style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
      Text(tr('صلاحيات الأدوار'), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      const SizedBox(height: 4),
      Text(tr('حدد صلاحيات كل دور في لوحة السيلز، وبعدها تقدر تعمل استثناء لموظف بعينه تحت. المالك عنده كل الصلاحيات دايمًا.'),
          style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 12),
      // ---------------------------------------------------------------- the roles matrix
      Container(
        decoration: JphUi.box(isDark),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight: 52,
            dataRowMinHeight: 44,
            dataRowMaxHeight: 52,
            columnSpacing: 18,
            columns: [
              DataColumn(label: Text(tr('الصلاحية'), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
              DataColumn(label: Text(tr('المالك'), style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark)))),
              for (final r in roles)
                DataColumn(label: Text('${r['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
            ],
            rows: [
              for (final p in perms)
                DataRow(cells: [
                  DataCell(Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(tr('${p['ar']}'), style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                    Text(tr('${p['group']}'), style: TextStyle(fontSize: 11, color: JphUi.sub(isDark))),
                  ])),
                  const DataCell(Icon(Icons.check_rounded, color: Ar.green)),
                  for (final r in roles)
                    DataCell(Checkbox(
                      value: ((r['perms'] as List?) ?? const []).contains(p['key']),
                      onChanged: (v) => _setRole('${r['key']}', '${p['key']}', v == true),
                    )),
                ]),
            ],
          ),
        ),
      ),
      const SizedBox(height: 22),
      // ---------------------------------------------------------------- one employee's exceptions
      Text(tr('صلاحيات المستخدم'), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      Text(tr('الموظف بيورث صلاحيات دوره، إلا لو سمحت له أو منعته من صلاحية بعينها.'), style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      DropdownButtonFormField<String>(
        value: _emp,
        isExpanded: true,
        decoration: InputDecoration(labelText: tr('اختر المستخدم'), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
        items: [
          for (final e in emps)
            DropdownMenuItem(value: '${e['id']}', child: Text('${e['name']} — ${e['role'] ?? ''}${lm(e['overrides']).isNotEmpty ? '  •' : ''}', overflow: TextOverflow.ellipsis)),
        ],
        onChanged: (v) => setState(() => _emp = v),
      ),
      if (emp != null) ...[
        const SizedBox(height: 10),
        for (final p in perms) _empRow(emp, p, roles),
      ],
    ]);
  }

  Widget _empRow(Map<String, dynamic> e, Map<String, dynamic> p, List<Map<String, dynamic>> roles) {
    final role = roles.where((r) => r['key'] == e['roleKey']).firstOrNull;
    final inherited = ((role?['perms'] as List?) ?? const []).contains(p['key']);
    final ov = lm(e['overrides'])[p['key']];
    final value = ov == null ? 'inherit' : (ov == true ? 'allow' : 'deny');
    final effective = ov == null ? inherited : ov == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: JphUi.box(isDark),
      child: Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center, runSpacing: 8, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(effective ? Icons.check_circle_rounded : Icons.block_rounded, size: 18, color: effective ? Ar.green : Ar.red),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(tr('${p['ar']}'), style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
            Text('${tr('من دوره')}: ${inherited ? tr('مسموح') : tr('ممنوع')}', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark))),
          ]),
        ]),
        SegmentedButton<String>(
          showSelectedIcon: false,
          segments: [
            ButtonSegment(value: 'inherit', label: Text(tr('يرث'))),
            ButtonSegment(value: 'allow', label: Text(tr('سماح'))),
            ButtonSegment(value: 'deny', label: Text(tr('منع'))),
          ],
          selected: {value},
          onSelectionChanged: (s) => _setEmp('${e['id']}', '${p['key']}', s.first),
        ),
      ]),
    );
  }
}
