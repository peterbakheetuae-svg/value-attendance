import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'jph_form_ui.dart';
import 'glass_ui.dart';

/// One item of العهدة (mobile / laptop) — the same card on the العهدة page, its details page and «تسليم عهدة».
const custodyAccAr = {'charger': 'شاحن', 'cable': 'كابل', 'case': 'جراب', 'headset': 'سماعة', 'bag': 'شنطة', 'mouse': 'ماوس', 'other': 'أخرى'};
const custodyAssetCondAr = {'new': 'جديد', 'used_good': 'مستعمل بحالة جيدة', 'other': 'أخرى'};
/// condition when handed / received (custody record)
const custodyCondAr = {'new': 'جديد', 'good': 'كويس', 'fair': 'مقبول', 'damaged': 'تالف'};

String custodyDay(Object? v) {
  final s = '${v ?? ''}';
  final d = DateTime.tryParse(s.length >= 10 ? s.substring(0, 10) : s);
  return d == null ? '' : '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
}

class CustodyAssetCard extends StatelessWidget {
  final Map<String, dynamic> asset;
  final bool isDark;
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool selected;
  const CustodyAssetCard({super.key, required this.asset, required this.isDark, this.onTap, this.trailing, this.selected = false});

  @override
  Widget build(BuildContext context) {
    final x = asset;
    final laptop = x['assetType'] == 'laptop';
    final holder = x['holder'] as Map?;
    final retired = x['status'] == 'retired';
    return Opacity(
      opacity: retired ? 0.55 : 1,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: JphUi.box(isDark).copyWith(
            border: selected ? Border.all(color: JphUi.primary(isDark), width: 2) : null,
          ),
          child: Row(children: [
            JphUi.iconTile(isDark, laptop ? Icons.laptop_rounded : Icons.phone_android_rounded, holder != null ? Ar.green : Ar.green),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${x['name']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text(
                    [
                      if ('${x['serialNo'] ?? ''}'.isNotEmpty) '${laptop ? 'SN' : 'IMEI'}: ${x['serialNo']}',
                      if ('${x['lineNumber'] ?? ''}'.isNotEmpty) 'خط ${x['lineNumber']}',
                      if ('${x['specs'] ?? ''}'.isNotEmpty) '${x['specs']}',
                      custodyAssetCondAr['${x['condition']}'] ?? '',
                      ...((x['accessories'] as List?) ?? const []).map((a) => custodyAccAr['$a'] ?? '$a'),
                    ].where((e) => e.isNotEmpty).join(' • '),
                    style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                const SizedBox(height: 2),
                Text(
                    retired
                        ? 'مؤرشفة'
                        : holder != null
                            ? 'مع ${holder['name']} من ${custodyDay(holder['since'])}'
                            : 'متاحة للتسليم',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: holder != null ? Ar.green : Ar.green)),
              ]),
            ),
            if (trailing != null) trailing! else if (onTap != null) Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
          ]),
        ),
      ),
    );
  }
}

/// «تسليم عهدة» from an employee's page: the available items as cards (mobiles, then laptops); returns the one picked.
Future<Map<String, dynamic>?> pickCustodyAsset(BuildContext context, bool isDark) async {
  final r = await ApiService.post({'action': 'cash_get', 'path': '/custody/assets', 'query': {'available': '1'}});
  if (!context.mounted) return null;
  final assets = ((r['assets'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
  if (assets.isEmpty) {
    JphUi.toast(context, {'success': false, 'message': r['success'] == true ? 'مفيش عهدة متاحة — ضيفها الأول من الإعدادات ← العهدة' : '${r['message'] ?? ''}'});
    return null;
  }
  assets.sort((a, b) => '${b['assetType']}'.compareTo('${a['assetType']}')); // mobile before laptop
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.8),
        margin: const EdgeInsets.all(12),
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
        decoration: Glass.panel(isDark, r: 24),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text('اختار العهدة', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
            IconButton(onPressed: () => Navigator.pop(ctx), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
          ]),
          const SizedBox(height: 6),
          Flexible(
            child: ListView(shrinkWrap: true, children: [
              for (final a in assets) CustodyAssetCard(asset: a, isDark: isDark, onTap: () => Navigator.pop(ctx, a)),
            ]),
          ),
        ]),
      ),
    ),
  );
}
