import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';
import '../../widgets/custody_asset_card.dart';
import 'custody_asset_details_page.dart';
import '../../widgets/glass_ui.dart';

/// الإعدادات ← العهدة: the company's mobiles and laptops. Each item is added once here (button top-right), then
/// handed to an employee from his page ("تسليم عهدة" picks from this list) and used to fill the custody receipt form.
class CustodyAssetsPage extends StatelessWidget {
  const CustodyAssetsPage({super.key});

  static bool get visible => ApiService.can('custody.manage') || ApiService.can('custody.read_all');

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      return AppBackground(
        child: Directionality(
          textDirection: ui.TextDirection.rtl,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: _Body(isDark: isDark),
            ),
          ),
        ),
      );
    });
  }
}

class _Body extends StatefulWidget {
  final bool isDark;
  const _Body({required this.isDark});

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  int _tab = 0;
  final _keys = [GlobalKey<_AssetsListState>(), GlobalKey<_AssetsListState>()];

  Widget _square(IconData icon, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: Glass.panel(widget.isDark, r: 14),
          child: Icon(icon, color: JphUi.text(widget.isDark)),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final canAdd = ApiService.can('custody.manage');
    return Column(children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(children: [
          // RTL: the add button sits top-right, the back arrow top-left
          if (canAdd)
            _square(Icons.add_rounded, () async {
              final added = await _addSheet(context, isDark, _tab == 0 ? 'mobile' : 'laptop');
              if (added) _keys[_tab].currentState?.load();
            })
          else
            const SizedBox(width: 46),
          const Spacer(),
          Text('العهدة', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          const Spacer(),
          _square(Icons.arrow_forward_ios_rounded, () => Navigator.pop(context)),
        ]),
      ),
      Expanded(
        child: SwipeTabs(
          isDark: isDark,
          onChanged: (i) => setState(() => _tab = i),
          tabs: const [('موبايل', Icons.phone_android_rounded), ('كمبيوتر محمول', Icons.laptop_rounded)],
          pages: [
            _AssetsList(key: _keys[0], isDark: isDark, type: 'mobile'),
            _AssetsList(key: _keys[1], isDark: isDark, type: 'laptop'),
          ],
        ),
      ),
    ]);
  }
}

const _accAr = {'charger': 'شاحن', 'cable': 'كابل', 'case': 'جراب', 'headset': 'سماعة', 'bag': 'شنطة', 'mouse': 'ماوس', 'other': 'أخرى'};

/// Add one item (mobile / laptop) to the custody list.
Future<bool> _addSheet(BuildContext context, bool isDark, String type) async {
  final name = TextEditingController(), serial = TextEditingController(), line = TextEditingController(),
      specs = TextEditingController(), notes = TextEditingController();
  String cond = 'new';
  final acc = <String>{'charger'};
  final laptop = type == 'laptop';
  var saving = false;
  final accKeys = laptop ? const ['charger', 'cable', 'bag', 'mouse', 'other'] : const ['charger', 'cable', 'case', 'headset', 'other'];
  final ok = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            decoration: BoxDecoration(
              color: isDark ? const Color(0xF2262624) : Colors.white,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
            ),
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                Center(child: Container(width: 44, height: 5, decoration: BoxDecoration(color: Ar.grey.shade400, borderRadius: BorderRadius.circular(4)))),
                const SizedBox(height: 12),
                Text(laptop ? 'إضافة كمبيوتر محمول' : 'إضافة موبايل', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                const SizedBox(height: 14),
                JphUi.input(isDark: isDark, label: 'النوع / الماركة *', controller: name,
                    icon: laptop ? Icons.laptop_rounded : Icons.phone_android_rounded, big: false),
                const SizedBox(height: 12),
                JphUi.input(isDark: isDark, label: laptop ? 'سريل الجهاز / SN' : 'رقم الجهاز / IMEI', controller: serial,
                    icon: Icons.qr_code_rounded, number: !laptop, big: false),
                const SizedBox(height: 12),
                if (!laptop) ...[
                  JphUi.input(isDark: isDark, label: 'رقم الخط (اختياري)', controller: line, icon: Icons.sim_card_rounded, number: true, big: false),
                  const SizedBox(height: 12),
                ],
                if (laptop) ...[
                  JphUi.input(isDark: isDark, label: 'المواصفات (معالج / رام / هارد)', controller: specs, icon: Icons.memory_rounded, big: false),
                  const SizedBox(height: 12),
                ],
                Text('الحالة', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                const SizedBox(height: 6),
                JphUi.tabs(isDark, const [('جديد', Icons.fiber_new_rounded), ('مستعمل جيد', Icons.thumb_up_rounded), ('أخرى', Icons.more_horiz_rounded)],
                    const ['new', 'used_good', 'other'].indexOf(cond), (i) => set(() => cond = const ['new', 'used_good', 'other'][i])),
                const SizedBox(height: 12),
                Text('الملحقات', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                const SizedBox(height: 6),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  for (final k in accKeys)
                    FilterChip(
                      selected: acc.contains(k),
                      onSelected: (v) => set(() => v ? acc.add(k) : acc.remove(k)),
                      label: Text(_accAr[k]!, style: TextStyle(fontWeight: FontWeight.w700, color: acc.contains(k) ? Colors.white : JphUi.text(isDark))),
                      selectedColor: JphUi.primary(isDark),
                      checkmarkColor: Colors.white,
                    ),
                ]),
                const SizedBox(height: 12),
                JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.edit_note_rounded, big: false),
                const SizedBox(height: 16),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: saving
                        ? null
                        : () async {
                            if (name.text.trim().length < 2) {
                              JphUi.toast(ctx, {'success': false, 'message': 'اكتب النوع / الماركة'});
                              return;
                            }
                            set(() => saving = true);
                            final r = await ApiService.post({
                              'action': 'cash_post', 'path': '/custody/assets', 'ok': 'اتضافت للعهدة ✅',
                              'body': {
                                'assetType': type, 'name': name.text.trim(), 'serialNo': serial.text.trim(), 'lineNumber': line.text.trim(),
                                'specs': specs.text.trim(), 'condition': cond, 'accessories': acc.toList(), 'notes': notes.text.trim(),
                              },
                            });
                            if (!ctx.mounted) return;
                            JphUi.toast(ctx, r);
                            if (r['success'] == true) Navigator.pop(ctx, true);
                            set(() => saving = false);
                          },
                    style: ElevatedButton.styleFrom(backgroundColor: JphUi.primary(isDark), foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
                    child: const Text('حفظ', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    }),
  );
  return ok == true;
}

class _AssetsList extends StatefulWidget {
  final bool isDark;
  final String type;
  const _AssetsList({super.key, required this.isDark, required this.type});

  @override
  State<_AssetsList> createState() => _AssetsListState();
}

class _AssetsListState extends State<_AssetsList> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final r = await ApiService.post({'action': 'cash_get', 'path': '/custody/assets', 'query': {'type': widget.type}});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = r['success'] == true ? null : '${r['message'] ?? 'مش قادر أحمّل العهدة'}';
      _items = ((r['assets'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    });
  }

  Future<void> _retire(Map<String, dynamic> x) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        icon: const Icon(Icons.archive_rounded, color: Ar.amber, size: 40),
        title: const Text('أرشفة'),
        content: Text('«${x['name']}» هتتشال من القايمة ومش هتظهر في التسليم. تقدر ترجعها تاني من «المؤرشفة». متأكد؟', textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('إلغاء')),
          FilledButton(style: FilledButton.styleFrom(backgroundColor: Ar.amber), onPressed: () => Navigator.pop(ctx, true), child: const Text('أرشفة')),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    final r = await ApiService.post({'action': 'cash_post', 'path': '/custody/assets/${x['id']}/retire', 'body': {}, 'ok': 'اتشالت من القايمة'});
    if (!mounted) return;
    JphUi.toast(context, r);
    load();
  }

  Future<void> _restore(Map<String, dynamic> x) async {
    final r = await ApiService.post({'action': 'cash_post', 'path': '/custody/assets/${x['id']}/restore', 'body': {}, 'ok': 'رجعت للقايمة ✅'});
    if (!mounted) return;
    JphUi.toast(context, r);
    load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final active = _items.where((x) => x['status'] == 'active').toList();
    final withSomeone = active.where((x) => x['holder'] != null).length;
    return RefreshIndicator(
      onRefresh: load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 60), children: [
        JphUi.statGrid([
          JphUi.stat(isDark, 'الإجمالي', '${active.length}', Icons.inventory_2_rounded, Ar.accent),
          JphUi.stat(isDark, 'مع موظفين', '$withSomeone', Icons.person_rounded, Ar.green),
          JphUi.stat(isDark, 'متاح', '${active.length - withSomeone}', Icons.check_circle_rounded, Ar.green),
        ], phone: 3),
        const SizedBox(height: 12),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _error != null) Padding(padding: const EdgeInsets.all(30), child: Text(_error!, textAlign: TextAlign.center)),
        if (!_loading && _error == null && _items.isEmpty)
          Padding(
            padding: const EdgeInsets.all(30),
            child: Text('لسه مفيش — دوس + فوق على اليمين وضيف', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))),
          ),
        for (final x in [..._items.where((x) => x['status'] != 'retired'), ..._items.where((x) => x['status'] == 'retired')]) ...[
          if (x['status'] == 'retired' && identical(x, _items.firstWhere((y) => y['status'] == 'retired')))
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
              child: Text('المؤرشفة', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.sub(isDark))),
            ),
          CustodyAssetCard(
            asset: x,
            isDark: isDark,
            onTap: () async {
              await Navigator.push(context, MaterialPageRoute(builder: (_) => CustodyAssetDetailsPage(assetId: '${x['id']}')));
              load();
            },
            trailing: ApiService.can('custody.manage') && x['status'] == 'active' && x['holder'] == null
                ? IconButton(tooltip: 'أرشفة', onPressed: () => _retire(x), icon: Icon(Icons.archive_outlined, color: JphUi.sub(isDark)))
                : ApiService.can('custody.manage') && x['status'] == 'retired'
                    ? TextButton.icon(onPressed: () => _restore(x), icon: const Icon(Icons.unarchive_rounded), label: const Text('رجّعها'))
                    : null,
          ),
        ],
      ]),
    );
  }
}
