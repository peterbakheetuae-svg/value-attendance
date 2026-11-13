import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../l10n/app_localizations.dart'; // 🔥 استيراد الترجمة

// ================== Month Year Filter Sheet ==================
class MonthYearSheet extends StatefulWidget {
  final int tmpMonth;
  final int tmpYear;
  final bool isDark;
  final Function(int month, int year) onApply;
  /// optional «كل الشهور» (the cashbox tiles)
  final VoidCallback? onAll;
  final bool allSelected;

  const MonthYearSheet({
    super.key,
    required this.tmpMonth,
    required this.tmpYear,
    required this.isDark,
    required this.onApply,
    this.onAll,
    this.allSelected = false,
  });

  @override
  State<MonthYearSheet> createState() => _MonthYearSheetState();
}

class _MonthYearSheetState extends State<MonthYearSheet> {
  late int _selectedMonth;
  late int _selectedYear;

  @override
  void initState() {
    super.initState();
    _selectedMonth = widget.tmpMonth;
    _selectedYear = widget.tmpYear;
  }

  String _monthNameAr(int m) {
    const names = [
      "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
      "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"
    ];
    return names[(m - 1).clamp(0, 11)];
  }

  // 🔥 دالة لترجمة اسم الشهر حسب اللغة
  String _monthName(BuildContext context, int m) {
    if (Localizations.localeOf(context).languageCode == 'ar') {
      return _monthNameAr(m);
    }

    // 🔥 الإنجليزية
    switch (m) {
      case 1: return AppLocalizations.of(context, 'january');
      case 2: return AppLocalizations.of(context, 'february');
      case 3: return AppLocalizations.of(context, 'march');
      case 4: return AppLocalizations.of(context, 'april');
      case 5: return AppLocalizations.of(context, 'may');
      case 6: return AppLocalizations.of(context, 'june');
      case 7: return AppLocalizations.of(context, 'july');
      case 8: return AppLocalizations.of(context, 'august');
      case 9: return AppLocalizations.of(context, 'september');
      case 10: return AppLocalizations.of(context, 'october');
      case 11: return AppLocalizations.of(context, 'november');
      case 12: return AppLocalizations.of(context, 'december');
      default: return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    // 🔥 ترجمة النصوص
    final selectMonthYearText = AppLocalizations.of(context, 'select_month_year');
    final selectedPeriodText = AppLocalizations.of(context, 'selected_period');
    final yearText = AppLocalizations.of(context, 'year');
    final monthText = AppLocalizations.of(context, 'month');
    final applyText = AppLocalizations.of(context, 'apply');
    final cancelText = AppLocalizations.of(context, 'cancel');

    final years = List.generate(6, (i) => DateTime.now().year - 2 + i);
    final months = List.generate(12, (i) => i + 1);

    final yearIndex = years.indexOf(_selectedYear).clamp(0, years.length - 1);
    final monthIndex = months.indexOf(_selectedMonth).clamp(0, months.length - 1);

    return Container(
      margin: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          color: widget.isDark ? const Color(0xFF262624) : Colors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetHeader(
                title: selectMonthYearText, // 🔥 استخدام الترجمة
                icon: Icons.calendar_month_rounded,
                isDark: widget.isDark,
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: widget.isDark ? AppColors.primaryLight.withOpacity(0.3) : const Color(0xFFE6E3DE),
                    width: 1.4,
                  ),
                  color: widget.isDark ? Colors.white.withOpacity(0.1) : const Color(0xFFF4F2EE),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: widget.isDark ? AppColors.primaryLight : AppColors.primary,
                      ),
                      child: const Icon(Icons.check_rounded, color: Colors.white, size: 30),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            selectedPeriodText, // 🔥 استخدام الترجمة
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: widget.isDark ? Colors.white70 : Colors.black54,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            "${_monthName(context, _selectedMonth)} $_selectedYear", // 🔥 استخدام الترجمة
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              color: widget.isDark ? AppColors.primaryLight : AppColors.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              Container(
                height: 260,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: widget.isDark ? Colors.white.withOpacity(0.2) : const Color(0xFFE6E3DE),
                  ),
                  color: widget.isDark ? Colors.black.withOpacity(0.6) : Colors.white.withOpacity(0.95),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          Text(
                            yearText, // 🔥 استخدام الترجمة
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: widget.isDark ? Colors.white : Colors.black,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: FixedExtentScrollController(initialItem: yearIndex),
                              itemExtent: 44,
                              onSelectedItemChanged: (i) {
                                setState(() => _selectedYear = years[i]);
                              },
                              children: [
                                for (final y in years)
                                  Center(
                                    child: Text(
                                      "$y",
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        color: (y == _selectedYear) ? (widget.isDark ? AppColors.primaryLight : AppColors.primary) : (widget.isDark ? Colors.white : Colors.black),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      width: 2,
                      color: widget.isDark ? AppColors.primaryLight.withOpacity(0.15) : AppColors.primary.withOpacity(0.15),
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          const SizedBox(height: 12),
                          Text(
                            monthText, // 🔥 استخدام الترجمة
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              color: widget.isDark ? Colors.white : Colors.black,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Expanded(
                            child: CupertinoPicker(
                              scrollController: FixedExtentScrollController(initialItem: monthIndex),
                              itemExtent: 44,
                              onSelectedItemChanged: (i) {
                                setState(() => _selectedMonth = months[i]);
                              },
                              children: [
                                for (final m in months)
                                  Center(
                                    child: Text(
                                      _monthName(context, m), // 🔥 استخدام الترجمة
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        color: (m == _selectedMonth) ? (widget.isDark ? AppColors.primaryLight : AppColors.primary) : (widget.isDark ? Colors.white : Colors.black),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.onAll != null) ...[
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: OutlinedButton.icon(
                    onPressed: widget.onAll,
                    icon: Icon(Icons.all_inclusive_rounded, color: widget.isDark ? AppColors.primaryLight : AppColors.primary),
                    label: Text('كل الشهور', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900,
                        color: widget.isDark ? AppColors.primaryLight : AppColors.primary)),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: widget.allSelected ? (widget.isDark ? AppColors.primaryLight : AppColors.primary).withOpacity(0.12) : null,
                      side: BorderSide(color: widget.isDark ? AppColors.primaryLight : AppColors.primary, width: widget.allSelected ? 2 : 1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              _SheetActions(
                onApply: () => widget.onApply(_selectedMonth, _selectedYear),
                onCancel: () => Navigator.pop(context),
                applyText: applyText, // 🔥 استخدام الترجمة
                cancelText: cancelText, // 🔥 استخدام الترجمة
                isDark: widget.isDark,
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ================== Range Filter Sheet ==================
class RangeSheet extends StatefulWidget {
  final DateTime tmpStart;
  final DateTime tmpEnd;
  final bool isDark;
  final Function(DateTime start, DateTime end) onApply;

  const RangeSheet({
    super.key,
    required this.tmpStart,
    required this.tmpEnd,
    required this.isDark,
    required this.onApply,
  });

  @override
  State<RangeSheet> createState() => _RangeSheetState();
}

class _RangeSheetState extends State<RangeSheet> {
  late DateTime _selectedStart;
  late DateTime _selectedEnd;

  @override
  void initState() {
    super.initState();
    _selectedStart = widget.tmpStart;
    _selectedEnd = widget.tmpEnd;
  }

  Future<void> _selectDate(BuildContext context, bool isStart) async {
    final locale = Localizations.localeOf(context).languageCode == 'ar'
        ? const Locale('ar')
        : const Locale('en');

    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _selectedStart : _selectedEnd,
      firstDate: DateTime(2020, 1, 1),
      lastDate: DateTime(2035, 12, 31),
      locale: locale, // 🔥 استخدام اللغة الحالية
    );

    if (picked != null) {
      setState(() {
        if (isStart) {
          _selectedStart = picked;
        } else {
          _selectedEnd = picked;
        }
      });
    }
  }

  String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yy = d.year.toString();
    return "$dd/$mm/$yy";
  }

  @override
  Widget build(BuildContext context) {
    // 🔥 ترجمة النصوص
    final selectDateRangeText = AppLocalizations.of(context, 'select_date_range');
    final startDateText = AppLocalizations.of(context, 'start_date');
    final endDateText = AppLocalizations.of(context, 'end_date');
    final applyText = AppLocalizations.of(context, 'apply');
    final cancelText = AppLocalizations.of(context, 'cancel');

    return Container(
      margin: const EdgeInsets.all(16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
          color: widget.isDark ? const Color(0xFF262624) : Colors.white,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetHeader(
                title: selectDateRangeText, // 🔥 استخدام الترجمة
                icon: Icons.calendar_month_rounded,
                isDark: widget.isDark,
              ),
              const SizedBox(height: 14),
              _RangeRow(
                title: startDateText, // 🔥 استخدام الترجمة
                value: _fmtDate(_selectedStart),
                icon: Icons.event_available_rounded,
                onTap: () => _selectDate(context, true),
                isDark: widget.isDark,
              ),
              const SizedBox(height: 12),
              _RangeRow(
                title: endDateText, // 🔥 استخدام الترجمة
                value: _fmtDate(_selectedEnd),
                icon: Icons.event_busy_rounded,
                onTap: () => _selectDate(context, false),
                isDark: widget.isDark,
              ),
              const SizedBox(height: 18),
              _SheetActions(
                onApply: () => widget.onApply(_selectedStart, _selectedEnd),
                onCancel: () => Navigator.pop(context),
                applyText: applyText, // 🔥 استخدام الترجمة
                cancelText: cancelText, // 🔥 استخدام الترجمة
                isDark: widget.isDark,
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

// ================== Shared Widgets ==================
class _SheetHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isDark;

  const _SheetHeader({
    required this.title,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFF0EDE8),
          ),
          child: Icon(
            icon,
            color: isDark ? AppColors.primaryLight : AppColors.primary,
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RangeRow extends StatelessWidget {
  final String title;
  final String value;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDark;

  const _RangeRow({
    required this.title,
    required this.value,
    required this.icon,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(
            color: isDark ? AppColors.primaryLight.withOpacity(0.3) : const Color(0xFFE6E3DE),
            width: 1.2,
          ),
          color: isDark ? Colors.white.withOpacity(0.1) : const Color(0xFFF7F6FF),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 16,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFF0EDE8),
              ),
              child: Icon(
                icon,
                color: isDark ? AppColors.primaryLight : AppColors.primary,
                size: 26,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: isDark ? Colors.white : Colors.black,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.chevron_left_rounded,
              color: isDark ? Colors.white70 : Colors.black54,
              size: 26,
            ),
          ],
        ),
      ),
    );
  }
}

class _SheetActions extends StatelessWidget {
  final VoidCallback onApply;
  final VoidCallback onCancel;
  final String applyText;
  final String cancelText;
  final bool isDark;

  const _SheetActions({
    required this.onApply,
    required this.onCancel,
    required this.applyText,
    required this.cancelText,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: onApply,
              child: Text(
                applyText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 52,
            child: TextButton(
              onPressed: onCancel,
              child: Text(
                cancelText,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}