import 'side_sheet.dart';
import 'package:flutter/material.dart';
import 'glass_ui.dart';

import '../pages/attendance/attendance_filters.dart';
import '../theme/app_colors.dart';

/// The app's own building blocks (same look as "طلب سلفة / مصاريف" and "صرف مالية"):
/// white / glass boxes with radius 20, a 44×44 icon tile, label 14 / value 18, bottom sheets with a handle.
class JphUi {
  /// every card of the app: the «Ardena» glass square (smoked glass in dark, frosted paper in light)
  static BoxDecoration box(bool isDark, {bool border = true}) {
    final g = Glass.panel(isDark, r: 20);
    return border ? g : g.copyWith(border: Border.all(color: Colors.transparent, width: 0));
  }

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
            decoration: Glass.panel(isDark, r: 14),
            child: Icon(isRTL ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded, color: t, size: 22),
          ),
        ),
        Expanded(child: Text(title, textAlign: TextAlign.center, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: t))),
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
              Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: sub(isDark))),
              const SizedBox(height: 4),
              Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: text(isDark))),
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
        Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: sub(isDark))),
        TextField(
          controller: controller,
          onChanged: onChanged,
          keyboardType: number ? const TextInputType.numberWithOptions(decimal: true) : TextInputType.text,
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: sub(isDark), fontSize: 13.5),
            border: InputBorder.none,
            prefixIcon: icon == null ? null : Icon(icon, color: primary(isDark), size: 22),
            suffixText: suffix,
            contentPadding: const EdgeInsets.symmetric(vertical: 10),
          ),
          style: TextStyle(fontSize: big ? 17 : 14, fontWeight: FontWeight.w800, color: text(isDark)),
        ),
      ]),
    );
  }

  /// A read-only computed value (the employee can't edit it).
  static Widget readOnly({required bool isDark, required String label, required String value, required IconData icon, Color? color}) {
    final c = color ?? Ar.green;
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
              Flexible(child: Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sub(isDark)))),
            ]),
            const SizedBox(height: 4),
            (value.endsWith('جنيه') || value.endsWith('%') ? CountUpText(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: text(isDark))) : Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: text(isDark)))),
          ]),
        ),
      ]),
    );
  }

  /// The one drop-down list of the app — same look as "نوع الطلب" in طلبات المالية: a floating rounded card with a title,
  /// a close button and each choice as a tile with its icon, the current one ticked.
  static Future<T?> sheet<T>(BuildContext context, bool isDark, String title, List<(T, String, IconData?)> options,
      {T? selected, IconData? icon, Color? color}) {
    final c = color ?? primary(isDark);
    return showAppSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Directionality(
        textDirection: Directionality.of(context),
        child: Container(
          margin: const EdgeInsets.all(16),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.75),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(26),
            child: Container(
              padding: const EdgeInsets.all(18),
              color: isDark ? const Color(0xFF262624) : Colors.white,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Row(children: [
                  Icon(icon ?? Icons.list_alt_rounded, color: c, size: 28),
                  Expanded(
                    child: Text(title, textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: isDark ? Colors.white : Colors.black87)),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: Icon(Icons.close_rounded, color: isDark ? Colors.white70 : Ar.grey.shade600, size: 28),
                  ),
                ]),
                const SizedBox(height: 16),
                if (options.isEmpty)
                  Padding(padding: const EdgeInsets.all(20), child: Text('مفيش اختيارات متاحة', style: TextStyle(color: sub(isDark))))
                else
                  Flexible(
                    child: ListView(shrinkWrap: true, children: [
                      for (final o in options)
                        _sheetTile(isDark, o.$2, o.$3 ?? icon ?? Icons.circle_outlined, c, o.$1 == selected && selected != null,
                            () => Navigator.pop(ctx, o.$1)),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
      ),
    );
  }

  static Widget _sheetTile(bool isDark, String label, IconData icon, Color c, bool on, VoidCallback onTap) => GestureDetector(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: on ? c.withOpacity(isDark ? 0.3 : 0.15) : (isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade50),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
                color: on ? c.withOpacity(0.5) : (isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300), width: on ? 1.5 : 1),
          ),
          child: Row(children: [
            iconTile(isDark, icon, c),
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: isDark ? Colors.white : Colors.black87)),
            ),
            if (on) Icon(Icons.check_circle_rounded, color: c, size: 24),
          ]),
        ),
      );

  /// Month filter — the same sheet as تقرير الحضور.
  static Future<DateTime?> pickMonth(BuildContext context, bool isDark, DateTime current) {
    return showAppSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => MonthYearSheet(
        tmpMonth: current.month,
        tmpYear: current.year,
        isDark: isDark,
        onApply: (m, y) => Navigator.pop(ctx, DateTime(y, m)),
      ),
    );
  }

  /// The same month sheet + «كل الشهور»: returns [allMonths] for every month, a month, or null (closed).
  static final DateTime allMonths = DateTime(1);
  static Future<DateTime?> pickMonthOrAll(BuildContext context, bool isDark, DateTime? current) {
    final c = current ?? DateTime.now();
    return showAppSheet<DateTime>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => MonthYearSheet(
        tmpMonth: c.month,
        tmpYear: c.year,
        isDark: isDark,
        allSelected: current == null,
        onAll: () => Navigator.pop(ctx, allMonths),
        onApply: (m, y) => Navigator.pop(ctx, DateTime(y, m)),
      ),
    );
  }

  /// Date range filter — the same sheet as تقرير الحضور.
  static Future<DateTimeRange?> pickRange(BuildContext context, bool isDark, DateTime start, DateTime end) {
    return showAppSheet<DateTimeRange>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => RangeSheet(
        tmpStart: start,
        tmpEnd: end,
        isDark: isDark,
        onApply: (s, e) => Navigator.pop(ctx, DateTimeRange(start: s, end: e.isBefore(s) ? s : e)),
      ),
    );
  }

  /// The filter button (as in تقرير الحضور), showing the current choice.
  static Widget filterButton(bool isDark, String label, VoidCallback onTap) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: ElevatedButton.icon(
            onPressed: onTap,
            icon: const Icon(Icons.filter_alt_rounded, size: 20),
            label: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w800)),
            style: ElevatedButton.styleFrom(
              backgroundColor: primary(isDark),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              elevation: 4,
            ),
          ),
        ),
      );

  /// The tab bar of the home page (الحضور / الاستراحة / الإجازة): a glass pill, the chosen tab filled.
  static Widget tabs(bool isDark, List<(String, IconData)> items, int index, ValueChanged<int> onTap) {
    final p = primary(isDark);
    final t = isDark ? Colors.white : Colors.black;
    return Container(
      padding: const EdgeInsets.all(6),
      decoration: Glass.tile(isDark, r: 30),
      child: Row(children: [
        for (var i = 0; i < items.length; i++)
          Expanded(
            child: GestureDetector(
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(color: i == index ? p : Colors.transparent, borderRadius: BorderRadius.circular(24)),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(items[i].$2, color: i == index ? Colors.white : t, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(items[i].$1, maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: i == index ? Colors.white : t, fontWeight: FontWeight.w600)),
                  ),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  /// Status chip used in lists.
  static Widget chip(String label, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withOpacity(0.14), borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withOpacity(0.5))),
        child: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12)),
      );

  /// The summary box of the app (as in ملخص المالية): tinted card, icon in a small square, title, value in the colour.
  static Widget stat(bool isDark, String label, String value, IconData icon, Color color) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: color.withOpacity(isDark ? 0.2 : 0.1),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 6, offset: const Offset(0, 3))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            width: 36, height: 36,
            decoration: Glass.tile(isDark, r: 10),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 8),
          Text(label, textAlign: TextAlign.center, maxLines: 2,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: isDark ? Colors.white70 : Ar.grey.shade700)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: CountUpText(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: color)),
          ),
        ]),
      );

  /// A row / grid of [stat] boxes (2 per row on phones, more on wide screens).
  static Widget statGrid(List<Widget> boxes, {int phone = 2}) => LayoutBuilder(builder: (context, c) {
        final cols = c.maxWidth > 700 ? (boxes.length >= 4 ? 4 : boxes.length) : phone;
        final w = (c.maxWidth - (cols - 1) * 8) / cols;
        return Wrap(spacing: 8, runSpacing: 8, children: [for (final b in boxes) SizedBox(width: w, child: b)]);
      });

  static void toast(BuildContext context, Map<String, dynamic> r) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Ar.green : Ar.red));
  }
}

/// Request / commission status in Arabic with a colour.
(String, Color) commissionStatus(String? s) => switch (s) {
      'approved' => ('معتمدة', Ar.green),
      'rejected' => ('مرفوضة', Ar.red),
      'voided' => ('ملغاة', Ar.grey),
      _ => ('مستنية الاعتماد', Ar.amber),
    };

(String, Color) paymentStatus(String? s) => switch (s) {
      'paid' => ('اتصرفت', Ar.green),
      'handed' => ('اتسلمت للموظف — مستني التأكيد', Ar.green),
      'cancelled' => ('ملغاة', Ar.grey),
      _ => ('لسه ماتصرفتش', Ar.amber),
    };
