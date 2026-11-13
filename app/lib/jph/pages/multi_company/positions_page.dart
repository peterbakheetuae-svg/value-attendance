import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../services/api_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/glass_ui.dart';

/// Job positions + their permissions, read from the server: any new position shows up here
/// automatically. Permissions are enforced by the API; this page only edits them.
class PositionsPage extends StatefulWidget {
  const PositionsPage({super.key});

  @override
  State<PositionsPage> createState() => _PositionsPageState();
}

/// Arabic label + group for each permission key (unknown keys still show, by key).
const Map<String, List<String>> _permLabels = {
  'employee.read_all': ['الموظفين', 'عرض كل الموظفين'],
  'employee.read_team': ['الموظفين', 'عرض موظفي فريقه'],
  'employee.manage': ['الموظفين', 'إضافة وتعديل وإيقاف الموظفين'],
  'employee.salary_read': ['الموظفين', 'عرض المرتبات'],
  'employee.salary_manage': ['الموظفين', 'تعديل المرتبات'],
  'documents.read': ['الموظفين', 'عرض مستندات الموظفين'],
  'documents.manage': ['الموظفين', 'رفع واستبدال مستندات الموظفين'],
  'custody.read_all': ['العُهد', 'عرض عُهد كل الموظفين'],
  'custody.read_team': ['العُهد', 'عرض عُهد فريقه'],
  'custody.manage': ['العُهد', 'تسليم واستلام العُهد'],
  'org.manage': ['الإدارة', 'إدارة الأقسام والفرق'],
  'positions.manage': ['الإدارة', 'إضافة وتعديل الوظائف'],
  'roles.manage': ['الإدارة', 'تعديل الصلاحيات'],
  'settings.manage': ['الإدارة', 'إعدادات الشركة'],
  'audit.read': ['الإدارة', 'سجل المراجعة'],
  'attendance.read_all': ['الحضور', 'عرض حضور الكل'],
  'attendance.read_team': ['الحضور', 'عرض حضور فريقه'],
  'attendance.correct': ['الحضور', 'تصحيح الحضور'],
  'attendance.config': ['الحضور', 'المواعيد والإجازات ومواقع العمل'],
  'request.read_all': ['الطلبات', 'عرض كل الطلبات'],
  'request.read_team': ['الطلبات', 'عرض طلبات فريقه'],
  'request.approve_manager': ['الطلبات', 'الموافقة كمدير مباشر'],
  'request.approve_hr': ['الطلبات', 'الموافقة كموارد بشرية'],
  'leave.manage_balances': ['الطلبات', 'إدارة أرصدة الإجازات'],
  'kpi.config': ['الأداء', 'إعداد مؤشرات الأداء'],
  'kpi.enter_all': ['الأداء', 'إدخال نتائج الكل'],
  'kpi.enter_team': ['الأداء', 'إدخال نتائج فريقه'],
  'kpi.read_all': ['الأداء', 'عرض أداء الكل'],
  'kpi.read_team': ['الأداء', 'عرض أداء فريقه'],
  'evaluation.write_all': ['الأداء', 'تقييم أي موظف'],
  'evaluation.write_team': ['الأداء', 'تقييم فريقه'],
  'evaluation.read_all': ['الأداء', 'عرض كل التقييمات'],
  'evaluation.read_team': ['الأداء', 'عرض تقييمات فريقه'],
  'report.read_all': ['التقارير', 'تقارير الشركة'],
  'report.read_team': ['التقارير', 'تقارير فريقه'],
  'report.payroll': ['التقارير', 'ملخص المرتبات'],
  'finance.read': ['المالية', 'عرض التسويات المالية'],
  'finance.manage': ['المالية', 'إنشاء تسويات مالية'],
  'finance.approve': ['المالية', 'اعتماد التسويات المالية'],
  'finance.disburse': ['المالية', 'صرف القبض والسلف والعمولات من العهدة'],
  'finance.fund': ['المالية', 'صرف أموال للموارد البشرية'],
  'notification.send': ['الإشعارات', 'إرسال إشعارات للموظفين'],
  'employee.attendance_exempt': ['الموظفين', 'تفعيل "ليس لديه حضور وانصراف"'],
};

const _baseRoles = {
  'sales_employee': 'موظف مبيعات',
  'sales_manager': 'مدير مبيعات',
  'hr_manager': 'موارد بشرية',
  'accountant': 'محاسب',
  'manager': 'المدير',
};

class _PositionsPageState extends State<PositionsPage> {
  List<Map<String, dynamic>> _roles = [];
  List<String> _allPerms = [];
  bool _canEditPerms = false;
  bool _canManage = false;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = ''; });
    final r = await ApiService.post({'action': 'get_roles'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['success'] == true) {
        _roles = ((r['roles'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _allPerms = ((r['permissions'] as List?) ?? const []).whereType<Map>().map((m) => '${m['key']}').toList();
        _canEditPerms = r['canEditPermissions'] == true;
        _canManage = r['canManagePositions'] == true;
      } else {
        _error = '${r['message'] ?? ''}';
      }
    });
  }

  void _snack(Map<String, dynamic> r) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Ar.green : Ar.red,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('الوظائف والصلاحيات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
          actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)],
        ),
        floatingActionButton: _canManage
            ? FloatingActionButton.extended(
                backgroundColor: AppColors.primary,
                onPressed: () => _editPosition(null),
                icon: const Icon(Icons.add, color: Colors.white),
                label: const Text('وظيفة جديدة', style: TextStyle(color: Colors.white)),
              )
            : null,
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error.isNotEmpty
                ? Center(child: Text(_error, textAlign: TextAlign.center))
                : RefreshIndicator(
                    onRefresh: _load,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
                      children: [
                        Text('أي وظيفة جديدة بتظهر هنا تلقائياً. الوظيفة الجديدة بتبدأ بنفس صلاحيات الدور اللي بتتبعه بالظبط، وبعدين المالك يقدر يزوّد أو يقلّل.',
                            style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariantLight)),
                        const SizedBox(height: 12),
                        ..._roles.map(_card),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _card(Map<String, dynamic> r) {
    final isDark = Provider.of<AppController>(context).isDark;
    final perms = ((r['permissions'] as List?) ?? const []).map((e) => '$e').toSet();
    final active = r['active'] != false;
    final builtin = r['builtin'] == true;
    final locked = r['key'] == 'owner' || r['key'] == 'sales_employee';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            tilePadding: EdgeInsets.zero,
            leading: Icon(builtin ? Icons.verified_user_rounded : Icons.work_outline_rounded,
                color: active ? AppColors.primary : Ar.grey),
            title: Text('${r['name_ar']}', style: TextStyle(fontWeight: FontWeight.w700, color: active ? null : Ar.grey)),
            subtitle: Text([
              builtin ? 'دور أساسي' : 'تتبع: ${r['base_name_ar'] ?? _baseRoles[r['base_key']] ?? ''}',
              '${r['employee_count'] ?? 0} موظف',
              '${perms.length} صلاحية',
              if (!active) 'متوقفة',
            ].join(' • '), style: TextStyle(fontSize: 12, color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight)),
            children: [
              if ('${r['description'] ?? ''}'.isNotEmpty)
                Align(alignment: AlignmentDirectional.centerStart, child: Padding(
                  padding: const EdgeInsets.only(bottom: 8), child: Text('${r['description']}'))),
              if (_canManage && (!builtin || _canEditPerms))
                Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(onPressed: () => _editPosition(r), icon: const Icon(Icons.edit_outlined), label: const Text('تعديل الوظيفة')),
                ),
              if (r['key'] == 'owner')
                const Padding(padding: EdgeInsets.all(8), child: Text('المالك عنده كل الصلاحيات دايماً'))
              else if (r['key'] == 'sales_employee')
                const Padding(padding: EdgeInsets.all(8), child: Text('موظف المبيعات خدمة ذاتية بس (بياناته وطلباته)'))
              else
                ..._groups().entries.expand((g) => [
                      Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 2),
                        child: Align(alignment: AlignmentDirectional.centerStart,
                            child: Text(g.key, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.primary))),
                      ),
                      ...g.value.map((k) => CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            value: perms.contains(k),
                            title: Text(_permLabels[k]?[1] ?? k),
                            onChanged: !_canEditPerms || locked
                                ? null
                                : (v) async {
                                    final next = {...perms};
                                    v == true ? next.add(k) : next.remove(k);
                                    final res = await ApiService.post({'action': 'set_position_permissions', 'key': r['key'], 'permissions': next.toList()});
                                    _snack(res);
                                    _load();
                                  },
                          )),
                    ]),
            ],
          ),
        ),
      ),
    );
  }

  Map<String, List<String>> _groups() {
    final out = <String, List<String>>{};
    for (final k in _allPerms) {
      out.putIfAbsent(_permLabels[k]?[0] ?? 'أخرى', () => []).add(k);
    }
    return out;
  }

  InputDecoration _input(String label) => InputDecoration(labelText: label, border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)));

  Future<void> _editPosition(Map<String, dynamic>? r) async {
    final name = TextEditingController(text: '${r?['name_ar'] ?? ''}');
    final nameEn = TextEditingController(text: '${r?['name_en'] ?? ''}');
    final desc = TextEditingController(text: '${r?['description'] ?? ''}');
    String base = 'sales_employee';
    bool active = r?['active'] != false;
    final isDark = Provider.of<AppController>(context, listen: false).isDark;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? Ar.grey.shade900.withOpacity(0.98) : Colors.white.withOpacity(0.98),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Ar.grey.shade400, borderRadius: BorderRadius.circular(2)))),
              const SizedBox(height: 14),
              Text(r == null ? 'وظيفة جديدة' : 'تعديل الوظيفة', textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              TextField(controller: name, decoration: _input('اسم الوظيفة *')),
              const SizedBox(height: 10),
              TextField(controller: nameEn, decoration: _input('الاسم بالإنجليزي')),
              const SizedBox(height: 10),
              TextField(controller: desc, maxLines: 2, decoration: _input('وصف مختصر')),
              const SizedBox(height: 10),
              if (r == null)
                DropdownButtonFormField<String>(
                  value: base,
                  decoration: _input('بتتبع أي دور في النظام؟ *'),
                  items: _baseRoles.entries.map((e) => DropdownMenuItem(value: e.key, child: Text(e.value))).toList(),
                  onChanged: (v) => set(() => base = v ?? base),
                ),
              if (r != null && r['builtin'] != true)
                SwitchListTile(contentPadding: EdgeInsets.zero, value: active, title: const Text('الوظيفة شغالة'), onChanged: (v) => set(() => active = v)),
              const SizedBox(height: 16),
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                  onPressed: () async {
                    if (name.text.trim().length < 2) {
                      ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('اكتب اسم الوظيفة'), backgroundColor: Ar.red));
                      return;
                    }
                    final res = r == null
                        ? await ApiService.post({'action': 'add_position', 'nameAr': name.text.trim(), 'nameEn': nameEn.text.trim(), 'baseKey': base, 'description': desc.text.trim()})
                        : await ApiService.post({'action': 'update_position', 'key': r['key'], 'nameAr': name.text.trim(),
                            if (nameEn.text.trim().isNotEmpty) 'nameEn': nameEn.text.trim(), 'description': desc.text.trim(),
                            if (r['builtin'] != true) 'active': active});
                    _snack(res);
                    if (res['success'] == true && ctx.mounted) Navigator.pop(ctx);
                  },
                  child: const Text('حفظ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      )),
    );
    _load();
  }
}
