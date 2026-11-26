import 'package:flutter/material.dart' hide Text;
import 'package:provider/provider.dart';
import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/glass_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// «إعدادات الإشعارات»: which categories of notifications this person receives. The server sends the categories his
/// role can receive, marks the ones he must keep (locked) and decides every change — this screen only shows them.
class NotificationPreferencesPage extends StatefulWidget {
  const NotificationPreferencesPage({super.key});

  @override
  State<NotificationPreferencesPage> createState() => _NotificationPreferencesPageState();
}

class _NotificationPreferencesPageState extends State<NotificationPreferencesPage> {
  List<Map<String, dynamic>> _cats = [];
  bool _installed = true;
  bool _loading = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await ApiService.post({'action': 'get_notification_prefs'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (r['success'] != true) {
        _error = '${r['message'] ?? 'تعذّر التحميل'}';
        return;
      }
      _installed = r['installed'] != false;
      _cats = ((r['categories'] as List?) ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final list = [
      for (final c in _cats)
        if (c['locked'] != true) {'key': c['key'], 'enabled': c['enabled'] == true},
    ];
    final r = await ApiService.post({'action': 'save_notification_prefs', 'categories': list});
    if (!mounted) return;
    setState(() => _saving = false);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Ar.green : Ar.red,
    ));
    if (r['success'] == true) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final sub = TextStyle(fontSize: 13, height: 1.5, color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight);
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: const Text('إعدادات الإشعارات', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  GlassCard(
                    child: Text('اختار أنواع الإشعارات اللي توصلك. اللي عليها قفل لازم تفضل شغالة لدورك. '
                        'تنبيهات الأمان وكود الاستلام ورسالة «إنت برة المكتب» بتوصل دايماً.', style: sub),
                  ),
                  const SizedBox(height: 14),
                  if (!_installed)
                    GlassCard(child: Text('الإعدادات دي هتشتغل بعد تحديث النظام.', style: sub))
                  else
                    for (final c in _cats)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GlassCard(
                          child: SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            value: c['enabled'] == true,
                            activeColor: AppColors.primary,
                            title: Text('${c['nameAr'] ?? c['key']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                            subtitle: c['locked'] == true ? Text('لازم تفضل شغالة لدورك', style: sub) : null,
                            secondary: c['locked'] == true ? const Icon(Icons.lock_outline_rounded) : null,
                            onChanged: c['locked'] == true ? null : (v) => setState(() => c['enabled'] = v),
                          ),
                        ),
                      ),
                  if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Ar.red))),
                  if (_installed && _cats.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 52,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                        onPressed: _saving ? null : _save,
                        child: Text(_saving ? 'جاري الحفظ...' : 'حفظ', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
                      ),
                    ),
                  ],
                ],
              ),
      ),
    );
  }
}
