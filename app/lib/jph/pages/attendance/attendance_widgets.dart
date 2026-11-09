import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../l10n/app_localizations.dart'; // 🔥 استيراد الترجمة
import 'attendance_daily_section.dart';
import 'attendance_monthly_section.dart';

// ================== Header ==================
class Header extends StatelessWidget {
  final VoidCallback onBack;
  final VoidCallback onFilter;
  final bool isRTL;
  final bool isDark;
  final String title;
  /// optional print icon, shown next to the filter icon
  final VoidCallback? onPrint;

  const Header({
    super.key,
    required this.onBack,
    required this.onFilter,
    required this.isRTL,
    required this.isDark,
    required this.title,
    this.onPrint,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: [
            SquareIconButton(
              icon: isRTL ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded,
              onTap: onBack,
              isDark: isDark,
            ),
            const Spacer(),
            Text(
              title,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight,
              ),
            ),
            const Spacer(),
            if (onPrint != null) ...[
              SquareIconButton(
                icon: Icons.print_rounded,
                onTap: onPrint!,
                isDark: isDark,
              ),
              const SizedBox(width: 8),
            ],
            SquareIconButton(
              icon: Icons.filter_list_rounded,
              onTap: onFilter,
              isDark: isDark,
            ),
          ],
        ),
      ),
    );
  }
}

// ================== Period Bar ==================
class PeriodBar extends StatelessWidget {
  final bool isMonthly;
  final int selMonth;
  final int selYear;
  final DateTime rangeStart;
  final DateTime rangeEnd;
  final bool isDark;

  const PeriodBar({
    super.key,
    required this.isMonthly,
    required this.selMonth,
    required this.selYear,
    required this.rangeStart,
    required this.rangeEnd,
    required this.isDark,
  });

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

  String _fmtDate(DateTime d) {
    final dd = d.day.toString().padLeft(2, '0');
    final mm = d.month.toString().padLeft(2, '0');
    final yy = d.year.toString();
    return "$dd/$mm/$yy";
  }

  @override
  Widget build(BuildContext context) {
    final text = isMonthly
        ? "${_monthName(context, selMonth)} $selYear" // 🔥 استخدام الترجمة
        : "${_fmtDate(rangeStart)} - ${_fmtDate(rangeEnd)}";

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: RepaintBoundary(
        child: GlassCard(
          radius: 18,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          isDark: isDark,
          child: Row(
            children: [
              const SizedBox(width: 6),
              Expanded(
                child: Center(
                  child: Text(
                    text,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SmallIcon(
                icon: Icons.calendar_month_rounded,
                isDark: isDark,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================== Top Stats ==================
class TopStats extends StatelessWidget {
  final bool isMonthly;
  final int topOk;
  final int topTotal;
  final bool isDark;
  final String label1; // 🔥 النص المترجم للتصنيف الأول
  final String label2; // 🔥 النص المترجم للتصنيف الثاني

  const TopStats({
    super.key,
    required this.isMonthly,
    required this.topOk,
    required this.topTotal,
    required this.isDark,
    required this.label1, // 🔥
    required this.label2, // 🔥
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Row(
          children: [
            Expanded(
              child: StatCard(
                value: "$topOk",
                label: label1, // 🔥 استخدام الترجمة
                icon: Icons.check_circle_rounded,
                softIconBg: isDark ? const Color(0xFF1A3D2C) : const Color(0xFFDFF3E6),
                iconColor: isDark ? const Color(0xFF4CAF50) : const Color(0xFF20A45A),
                valueColor: isDark ? const Color(0xFF4CAF50) : const Color(0xFF20A45A),
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: StatCard(
                value: "$topTotal",
                label: label2, // 🔥 استخدام الترجمة
                icon: Icons.calendar_month_rounded,
                softIconBg: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFE8E6FF),
                iconColor: isDark ? AppColors.primaryLight : AppColors.primary,
                valueColor: isDark ? AppColors.primaryLight : AppColors.primary,
                isDark: isDark,
              ),
            ),
          ],
        )
    );
  }
}

// ================== Tabs ==================
class Tabs extends StatelessWidget {
  final bool isMonthly;
  final ValueChanged<bool> onTabChange;
  final bool isDark;
  final String tab1Text; // 🔥 النص المترجم للتبويب الأول
  final String tab2Text; // 🔥 النص المترجم للتبويب الثاني

  const Tabs({
    super.key,
    required this.isMonthly,
    required this.onTabChange,
    required this.isDark,
    required this.tab1Text, // 🔥
    required this.tab2Text, // 🔥
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: RepaintBoundary(
        child: GlassCard(
          radius: 22,
          padding: const EdgeInsets.all(10),
          isDark: isDark,
          child: Row(
            children: [
              Expanded(
                child: PillTab(
                  active: isMonthly,
                  text: tab1Text, // 🔥 استخدام الترجمة
                  icon: Icons.calendar_month_rounded,
                  onTap: () => onTabChange(true),
                  isDark: isDark,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: PillTab(
                  active: !isMonthly,
                  text: tab2Text, // 🔥 استخدام الترجمة
                  icon: Icons.menu_rounded,
                  onTap: () => onTabChange(false),
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ================== Content ==================
class Content extends StatelessWidget {
  final bool isMonthly;
  final bool loading;
  final String? errorMessage;
  final Map<String, dynamic> monthly;
  final List<Map<String, dynamic>> daily;
  final bool isDark;
  final VoidCallback onReload;
  final int Function(dynamic) safeToInt;
  final String Function(dynamic) formatMoney;
  final String Function(dynamic) formatOvertime;
  // 🔥 النصوص المترجمة
  final String loadingText;
  final String noMonthlyDataText;
  final String noDailyDataText;
  final String errorText;
  final String retryText;

  const Content({
    super.key,
    required this.isMonthly,
    required this.loading,
    required this.errorMessage,
    required this.monthly,
    required this.daily,
    required this.isDark,
    required this.onReload,
    required this.safeToInt,
    required this.formatMoney,
    required this.formatOvertime,
    required this.loadingText, // 🔥
    required this.noMonthlyDataText, // 🔥
    required this.noDailyDataText, // 🔥
    required this.errorText, // 🔥
    required this.retryText, // 🔥
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(
                isDark ? AppColors.primaryLight : AppColors.primary,
              ),
              strokeWidth: 2,
            ),
            const SizedBox(height: 16),
            Text(
              loadingText, // 🔥 استخدام الترجمة
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ],
        ),
      );
    }

    if (errorMessage != null && isMonthly && monthly.isEmpty) {
      return ErrorState(
        message: errorMessage!,
        isDark: isDark,
        onRetry: onReload,
        errorText: errorText, // 🔥
        retryText: retryText, // 🔥
      );
    }

    if (errorMessage != null && !isMonthly && daily.isEmpty) {
      return ErrorState(
        message: errorMessage!,
        isDark: isDark,
        onRetry: onReload,
        errorText: errorText, // 🔥
        retryText: retryText, // 🔥
      );
    }

    if (isMonthly && monthly.isEmpty) {
      return EmptyState(
        message: noMonthlyDataText, // 🔥 استخدام الترجمة
        isDark: isDark,
        noDataText: AppLocalizations.of(context, 'no_data'), // 🔥
      );
    }

    if (!isMonthly && daily.isEmpty) {
      return EmptyState(
        message: noDailyDataText, // 🔥 استخدام الترجمة
        isDark: isDark,
        noDataText: AppLocalizations.of(context, 'no_data'), // 🔥
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 100),
      child: isMonthly
          ? MonthlySection(
        monthly: monthly,
        isDark: isDark,
        safeToInt: safeToInt,
        formatMoney: formatMoney,
        formatOvertime: formatOvertime,
      )
          : DailySection(
        daily: daily,
        isDark: isDark,
      ),
    );
  }
}

// ================== Filter FAB ==================
class FilterFab extends StatelessWidget {
  final bool isDark;
  final VoidCallback onPressed;
  final String text; // 🔥 النص المترجم

  const FilterFab({
    super.key,
    required this.isDark,
    required this.onPressed,
    required this.text, // 🔥
  });

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton.extended(
      onPressed: onPressed,
      icon: const Icon(Icons.filter_alt_rounded, size: 22),
      label: Text(
        text, // 🔥 استخدام الترجمة
        style: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
      backgroundColor: isDark ? AppColors.primaryLight : AppColors.primary,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
      ),
      elevation: 8,
    );
  }
}

// ================== Helper Widgets ==================
class SquareIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final bool isDark;

  const SquareIconButton({
    super.key,
    required this.icon,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.70),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 14,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Icon(
          icon,
          color: isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight,
          size: 22,
        ),
      ),
    );
  }
}

class SmallIcon extends StatelessWidget {
  final IconData icon;
  final bool isDark;

  const SmallIcon({
    super.key,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: isDark ? AppColors.primaryLight.withOpacity(0.3) : const Color(0xFFEDEBFF),
      ),
      child: Icon(
        icon,
        color: isDark ? AppColors.primaryLight : AppColors.primary,
        size: 22,
      ),
    );
  }
}

class StatCard extends StatelessWidget {
  final String value;
  final String label;
  final IconData icon;
  final Color softIconBg;
  final Color iconColor;
  final Color valueColor;
  final bool isDark;

  const StatCard({
    super.key,
    required this.value,
    required this.label,
    required this.icon,
    required this.softIconBg,
    required this.iconColor,
    required this.valueColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GlassCard(
        radius: 24,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        isDark: isDark,
        child: Row(
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: softIconBg,
              ),
              child: Icon(icon, color: iconColor, size: 28),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    value,
                    style: TextStyle(
                      fontSize: 26,
                      fontWeight: FontWeight.w900,
                      color: valueColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: isDark ? Colors.white70 : Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PillTab extends StatelessWidget {
  final bool active;
  final String text;
  final IconData icon;
  final VoidCallback onTap;
  final bool isDark;

  const PillTab({
    super.key,
    required this.active,
    required this.text,
    required this.icon,
    required this.onTap,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        height: 54,
        decoration: BoxDecoration(
          color: active ? primaryColor : Colors.transparent,
          borderRadius: BorderRadius.circular(18),
          boxShadow: active
              ? [
            BoxShadow(
              color: Colors.black.withOpacity(0.12),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ]
              : [],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              color: active ? Colors.white : (isDark ? Colors.white70 : Colors.black54),
              size: 22,
            ),
            const SizedBox(width: 10),
            Text(
              text,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: active ? Colors.white : (isDark ? Colors.white70 : Colors.black54),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final bool isDark;
  final double radius;

  const GlassCard({
    super.key,
    required this.child,
    required this.padding,
    required this.isDark,
    this.radius = 24,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
          ),
        ],
      ),
      child: child,
    );
  }
}

class ErrorState extends StatelessWidget {
  final String message;
  final bool isDark;
  final VoidCallback onRetry;
  final String errorText; // 🔥 النص المترجم للخطأ
  final String retryText; // 🔥 النص المترجم لإعادة المحاولة

  const ErrorState({
    super.key,
    required this.message,
    required this.isDark,
    required this.onRetry,
    required this.errorText, // 🔥
    required this.retryText, // 🔥
  });

  @override
  Widget build(BuildContext context) {
    return Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: isDark ? Colors.red.shade900.withOpacity(0.3) : Colors.red.shade50,
                  borderRadius: BorderRadius.circular(40),
                ),
                child: const Icon(
                  Icons.error_outline_rounded,
                  size: 40,
                  color: Colors.redAccent,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                errorText, // 🔥 استخدام الترجمة
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.red,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: isDark ? AppColors.primaryLight : AppColors.primary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                ),
                onPressed: onRetry,
                child: Text(
                  retryText, // 🔥 استخدام الترجمة
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        )
    );
  }
}

class EmptyState extends StatelessWidget {
  final String message;
  final bool isDark;
  final String noDataText; // 🔥 النص المترجم "لا توجد بيانات"

  const EmptyState({
    super.key,
    required this.message,
    required this.isDark,
    required this.noDataText, // 🔥
  });

  @override
  Widget build(BuildContext context) {
    return Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: isDark ? Colors.grey.shade800 : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(40),
                ),
                child: Icon(
                  Icons.hourglass_empty_rounded,
                  size: 40,
                  color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                noDataText, // 🔥 استخدام الترجمة
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Text(
                  message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.grey.shade400 : Colors.grey.shade600,
                  ),
                ),
              ),
            ],
          ),
        )
    );
  }
}
// ================== Employee Dropdown ==================
class EmployeeDropdown extends StatelessWidget {
  final List<Map<String, dynamic>> employees;
  final String? selectedUid;
  final String? selectedEmployeeName;
  final bool loading;
  final Function(String?, String?) onChanged;
  final bool isDark;
  final String selectEmployeeText;

  const EmployeeDropdown({
    super.key,
    required this.employees,
    required this.selectedUid,
    required this.selectedEmployeeName,
    required this.loading,
    required this.onChanged,
    required this.isDark,
    required this.selectEmployeeText,
  });

  @override
  Widget build(BuildContext context) {
    if (loading) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          children: [
            const SizedBox(
              width: 24,
              height: 24,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Text(
              AppLocalizations.of(context, 'loading_employees'),
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.black54,
              ),
            ),
          ],
        ),
      );
    }

    if (employees.isEmpty) {
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_rounded,
              color: isDark ? Colors.orangeAccent : Colors.orange,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                AppLocalizations.of(context, 'no_employees_found'),
                style: TextStyle(
                  fontSize: 14,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18.0, vertical: 10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: selectedUid,
            isExpanded: true,
            icon: Icon(
              Icons.arrow_drop_down,
              color: isDark ? Colors.white : Colors.black,
              size: 28,
            ),
            hint: Container(
              height: 40,
              alignment: Alignment.centerRight,
              child: Text(
                selectEmployeeText,
                style: TextStyle(
                  fontSize: 16,
                  color: isDark ? Colors.white70 : Colors.black54,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            style: TextStyle(
              fontSize: 16,
              color: isDark ? Colors.white : Colors.black,
              fontWeight: FontWeight.w600,
            ),
            dropdownColor: isDark ? const Color(0xFF1E1E1E) : Colors.white,
            borderRadius: BorderRadius.circular(16),
            itemHeight: 64, // 🔥 زيادة ارتفاع العنصر لمنع التدفق
            onChanged: (String? newValue) {
              if (newValue != null) {
                final selectedEmployee = employees.firstWhere(
                      (emp) => emp['uid'] == newValue,
                  orElse: () => {},
                );
                final name = selectedEmployee['name']?.toString();
                onChanged(newValue, name);
              }
            },
            items: employees.map<DropdownMenuItem<String>>((employee) {
              final uid = employee['uid']?.toString() ?? '';
              final name = employee['name']?.toString() ?? '';
              final role = employee['role']?.toString() ?? '';
              final isActive = employee['active'] == true;

              return DropdownMenuItem<String>(
                value: uid,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 6), // 🔥 تقليل الحشو الداخلي
                  constraints: const BoxConstraints(
                    minHeight: 56, // 🔥 تحديد ارتفاع أدنى
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min, // 🔥 استخدام أقل حجم ممكن
                    children: [
                      Text(
                        '$name ($uid)',
                        style: TextStyle(
                          fontSize: 14, // 🔥 تقليل حجم الخط
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2), // 🔥 تقليل المسافة
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Expanded(
                            child: Text(
                              role,
                              style: TextStyle(
                                fontSize: 11, // 🔥 تقليل حجم الخط
                                color: isDark ? Colors.white60 : Colors.black54,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: isActive ? Colors.green : Colors.red,
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            isActive
                                ? AppLocalizations.of(context, 'active')
                                : AppLocalizations.of(context, 'inactive'),
                            style: TextStyle(
                              fontSize: 10, // 🔥 تقليل حجم الخط
                              color: isActive ? Colors.green : Colors.red,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ),
      ),
    );
  }
}