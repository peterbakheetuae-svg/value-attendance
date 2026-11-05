import 'package:flutter/material.dart';

import '../theme/app_colors.dart';

/// The app's own building blocks (same look as "طلب سلفة / مصاريف" and "صرف مالية"):
/// white / glass boxes with radius 20, a 44×44 icon tile, label 14 / value 18, bottom sheets with a handle.
class JphUi {
  static BoxDecoration box(bool isDark, {bool border = true}) => BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)],
        border: border ? Border.all(color: isDark ? Colors.white.withOpacity(0.2) : Colors.grey.shade300, width: 1) : null,
      );

  static Color text(bool isDark) => isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
  static Color sub(bool isDark) => isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
  static Color primary(bool isDark) => isDark ? AppColors.primaryLight : AppColors.primary;

  static String money(Object? v) {
    final n = v is num ? v : num.tryParse('${v ?? ''}');
    if (n == null) return '--';
    final fixed = n == n.roundToDouble() ? n.round().toString() : n.toStringAsFixed(2);
    final parts = fixed.split('.');
    final whole = parts[0].replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    return '${parts.length > 1 ? '$whole.${parts[1]}' : whole} جنيه';
  }

  static String pct(Object? v) {
    final n = v is num ? v : num.tryParse('${v ?? ''}');
    if (n == null) return '--';
    var s = n.toStringAsFixed(4);
    s = s.replaceAll(RegExp(r'0+$'), '');
    if (s.endsWith('.')) s = '${s}00';
    if (RegExp(r'\.\d$').hasMatch(s)) s = '${s}0';
    return '$s%';
  }

  static const monthsAr = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  static String monthAr(String? ym) {
    if (ym == null || ym.length < 7) return '--';
    final m = int.tryParse(ym.substring(5, 7)) ?? 1;
    return '${monthsAr[m - 1]} ${ym.substring(0, 4)}';
  }

  static String date(Object? iso) {
    final d = DateTime.tryParse('${iso ?? ''}')?.toLocal();
    return d == null ? '--' : '${d.day}/${d.month}/${d.year}';
  }

  /// The page header: rounded back button, centred title, optional action on the other side.
  static Widget header(BuildContext context, {required bool isDark, required bool isRTL, required String title, Widget? action}) {
    final t = text(isDark);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      child: Row(children: [
        GestureDetector(
          onTap: () => Navigator.pop(context),
          child: Container(
            width: 46, height: 46,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.70),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.08), blurRadius: 14, offset: const Offset(0, 8))],
            ),
            child: Icon(isRTL ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded, color: t, size: 22),
          ),
        ),
        Expanded(child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: t))),
        SizedBox(width: 46, height: 46, child: action),
      ]),
    );
  }

  /// A tappable field that opens a sheet (project, month, status…).
  static Widget picker({required bool isDark, required IconData icon, required Color iconColor, required String label,
      required String value, required VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: box(isDark),
        child: Row(children: [
          iconTile(isDark, icon, iconColor),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: sub(isDark))),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: text(isDark))),
            ]),
          ),
          const SizedBox(width: 10),
          if (onTap != null) Icon(Icons.arrow_drop_down_rounded, color: AppColors.primary, size: 28),
        ]),
      ),
    );
  }

  static Widget iconTile(bool isDark, IconData icon, Color color) => Container(
        width: 44, height: 44,
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: color.withOpacity(isDark ? 0.2 : 0.1)),
        child: Icon(icon, color: color, size: 22),
      );

  /// A number / text field inside the same box.
  static Widget input({required bool isDark, required String label, required TextEditingController controller,
      String? hint, IconData? icon, bool number = false, ValueChanged<String>? onChanged, String? suffix, bool big = true}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(label, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: sub(isDark))),
        TextField(
          controller: controller,
          onChanged: onChanged,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: sub(isDark), fontSize: 15),
            border: InputBorder.none,
            prefixIcon: icon == null ? null : Icon(icon, color: primary(isDark), size: 22),
            suffixText: suffix,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          style: TextStyle(fontSize: big ? 20 : 16, fontWeight: FontWeight.w800, color: text(isDark)),
        ),
      ]),
    );
  }

  /// A read-only computed value (the employee can't edit it).
  static Widget readOnly({required bool isDark, required String label, required String value, required IconData icon, Color? color}) {
    final c = color ?? Colors.green;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: isDark ? c.withOpacity(0.15) : c.withOpacity(0.07),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withOpacity(isDark ? 0.5 : 0.35), width: 1.2),
      ),
      child: Row(children: [
        iconTile(isDark, icon, c),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Icon(Icons.lock_rounded, size: 13, color: sub(isDark)),
              const SizedBox(width: 4),
              Flexible(child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sub(isDark)))),
            ]),
            const SizedBox(height: 4),
            Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: text(isDark))),
          ]),
        ),
      ]),
    );
  }

  static Future<T?> sheet<T>(BuildContext context, bool isDark, String title, List<(T, String, IconData?)> options) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 44, height: 5, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(4))),
          const SizedBox(height: 12),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          if (options.isEmpty)
            const Padding(padding: EdgeInsets.all(20), child: Text('مفيش اختيارات متاحة'))
          else
            Flexible(
              child: ListView(shrinkWrap: true, children: [
                for (final o in options)
                  ListTile(
                    leading: o.$3 == null ? null : Icon(o.$3, color: AppColors.primary),
                    title: Text(o.$2, style: const TextStyle(fontWeight: FontWeight.w700)),
                    onTap: () => Navigator.pop(ctx, o.$1),
                  ),
              ]),
            ),
        ]),
      ),
    );
  }

  /// Status chip used in lists.
  static Widget chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.5))),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );

  /// Small stat card for summaries.
  static Widget stat(bool isDark, String label, String value, IconData icon, Color color) => Container(
        padding: const EdgeInsets.all(14),
        decoration: box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: 6),
            Expanded(child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: sub(isDark)))),
          ]),
          const SizedBox(height: 6),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: text(isDark))),
          ),
        ]),
      );

  static void toast(BuildContext context, Map<String, dynamic> r) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
  }
}

/// Request / commission status in Arabic with a colour.
(String, Color) commissionStatus(String? s) => switch (s) {
      'approved' => ('معتمدة', Colors.green),
      'rejected' => ('مرفوضة', Colors.red),
      'voided' => ('ملغاة', Colors.grey),
      _ => ('مستنية الاعتماد', Colors.orange),
    };

(String, Color) paymentStatus(String? s) => switch (s) {
      'paid' => ('اتصرفت', Colors.green),
      'handed' => ('اتسلمت للموظف — مستني التأكيد', Colors.teal),
      'cancelled' => ('ملغاة', Colors.grey),
      _ => ('لسه ماتصرفتش', Colors.orange),
    };
