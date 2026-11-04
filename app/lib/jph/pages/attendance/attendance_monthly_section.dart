import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../l10n/app_localizations.dart';

class MonthlySection extends StatelessWidget {
  final Map<String, dynamic> monthly;
  final bool isDark;
  final int Function(dynamic) safeToInt;
  final String Function(dynamic) formatMoney;
  final String Function(dynamic) formatOvertime;

  const MonthlySection({
    super.key,
    required this.monthly,
    required this.isDark,
    required this.safeToInt,
    required this.formatMoney,
    required this.formatOvertime,
  });

  // 🔥 دالة التحقق من وجود بيانات
  bool hasMonthlyData() {
    final workDays = safeToInt(monthly["workDays"]);
    final dueSalary = safeToInt(monthly["dueSalary"]);
    final arrears = safeToInt(monthly["arrears"]);

    // التحقق من وجود بيانات في الحقول المطلوبة
    return !(workDays == 0 && dueSalary == 0 && arrears == 0);
  }

  // 🔥 دالة بديلة للاستخدام الخارجي إذا احتجناها
  static bool hasData(Map<String, dynamic> monthly, int Function(dynamic) safeToInt) {
    final workDays = safeToInt(monthly['workDays']);
    final dueSalary = safeToInt(monthly['dueSalary']);
    final arrears = safeToInt(monthly['arrears']);

    return !(workDays == 0 && dueSalary == 0 && arrears == 0);
  }

  @override
  Widget build(BuildContext context) {
    // 🔥 التحقق من وجود بيانات قبل بناء الويدجت
    if (!hasMonthlyData()) {
      return _buildEmptyState(context);
    }

    return _buildMonthlySection(context);
  }

  // 🔥 ويدجت للحالة الفارغة
  Widget _buildEmptyState(BuildContext context) {
    final noDataText = AppLocalizations.of(context, 'no_monthly_data');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            AppLocalizations.of(context, 'monthly_report'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
              ),
            ],
          ),
          child: Center(
            child: Column(
              children: [
                Icon(
                  Icons.calendar_today_outlined,
                  size: 60,
                  color: isDark ? Colors.grey[400] : Colors.grey[500],
                ),
                const SizedBox(height: 16),
                Text(
                  noDataText,
                  style: TextStyle(
                    fontSize: 16,
                    color: isDark ? Colors.grey[400] : Colors.grey[600],
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 🔥 ويدجت لعرض البيانات الشهرية
  Widget _buildMonthlySection(BuildContext context) {
    // 🔥 ترجمة النصوص
    final monthlyReportTitle = AppLocalizations.of(context, 'monthly_report');
    final workDaysText = AppLocalizations.of(context, 'work_days');
    final holidayAttendText = AppLocalizations.of(context, 'without_pay');
    final holidaysText = AppLocalizations.of(context, 'holidays');
    final sickText = AppLocalizations.of(context, 'sick_leave');
    final absentText = AppLocalizations.of(context, 'absent');
    final overtimeHoursText = AppLocalizations.of(context, 'overtime_hours');
    final overtimeAmountText = AppLocalizations.of(context, 'overtime_amount');
    final attendSalaryText = AppLocalizations.of(context, 'attendance_salary');
    final allowanceText = AppLocalizations.of(context, 'allowances');
    final bonusText = AppLocalizations.of(context, 'extra_bonus');
    final workExpensesText = AppLocalizations.of(context, 'work_expenses');
    final deductionText = AppLocalizations.of(context, 'deductions');
    final absentDeductionText = AppLocalizations.of(context, 'absent_deduction');
    final advanceText = AppLocalizations.of(context, 'advance');
    final receivedText = AppLocalizations.of(context, 'received');
    final dueSalaryText = AppLocalizations.of(context, 'due_salary');
    final arrearsText = AppLocalizations.of(context, 'arrears');

    final w = safeToInt(monthly["workDays"]).toString();
    final ha = safeToInt(monthly["holidayAttend"]).toString();
    final h = safeToInt(monthly["holidays"]).toString();
    final s = safeToInt(monthly["sick"]).toString();
    final a = safeToInt(monthly["absent"]).toString();
    final oh = formatOvertime(monthly["overtimeHours"]);
    final oa = formatMoney(monthly["overtimeAmount"]);
    final attendSalary = formatMoney(monthly["attendSalary"]);
    final allowance = formatMoney(monthly["allowance"]);
    final bonus = formatMoney(monthly["bonus"]);
    final workExpenses = formatMoney(monthly["workExpenses"]);
    final deduction = formatMoney(monthly["deduction"]);
    final absentDeduction = formatMoney(monthly["absentDeduction"]);
    final advance = formatMoney(monthly["advance"]);
    final received = formatMoney(monthly["received"]);
    final dueSalary = formatMoney(monthly["dueSalary"]);
    final arrears = formatMoney(monthly["arrears"]);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.only(right: 4),
          child: Text(
            monthlyReportTitle,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.fromLTRB(14, 16, 14, 18),
          decoration: BoxDecoration(
            color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
            borderRadius: BorderRadius.circular(26),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.1),
                blurRadius: 10,
              ),
            ],
          ),
          child: Column(
            children: [
              MonthlyRow(
                left: MonthlyMini(
                  top: "Days $w",
                  bottom: workDaysText,
                  bottomColor: const Color(0xFF2E9B67),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "Days $ha",
                  bottom: holidayAttendText,
                  bottomColor: isDark ? AppColors.primaryLight : AppColors.primary,
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "Days $h",
                  bottom: holidaysText,
                  bottomColor: const Color(0xFFD0902D),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "Days $s",
                  bottom: sickText,
                  bottomColor: const Color(0xFFB54A3A),
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "Days $a",
                  bottom: absentText,
                  bottomColor: const Color(0xFFB54A3A),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "HR $oh",
                  bottom: overtimeHoursText,
                  bottomColor: isDark ? AppColors.primaryLight : AppColors.primary,
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "AED $oa",
                  bottom: overtimeAmountText,
                  bottomColor: isDark ? AppColors.primaryLight : AppColors.primary,
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "AED $attendSalary",
                  bottom: attendSalaryText,
                  bottomColor: const Color(0xFF2E9B67),
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "AED $allowance",
                  bottom: allowanceText,
                  bottomColor: const Color(0xFFD0902D),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "AED $bonus",
                  bottom: bonusText,
                  bottomColor: const Color(0xFFD0902D),
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "AED $workExpenses",
                  bottom: workExpensesText,
                  bottomColor: isDark ? AppColors.primaryLight : AppColors.primary,
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "AED $deduction",
                  bottom: deductionText,
                  bottomColor: const Color(0xFFB54A3A),
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "AED $absentDeduction",
                  bottom: absentDeductionText,
                  bottomColor: const Color(0xFFB54A3A),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "AED $advance",
                  bottom: advanceText,
                  bottomColor: const Color(0xFFB54A3A),
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "AED $received",
                  bottom: receivedText,
                  bottomColor: const Color(0xFF2E9B67),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "AED $dueSalary",
                  bottom: dueSalaryText,
                  bottomColor: isDark ? AppColors.primaryLight : AppColors.primary,
                  isDark: isDark,
                ),
              ),
              const SizedBox(height: 12),
              MonthlyRow(
                left: MonthlyMini(
                  top: "AED $arrears",
                  bottom: arrearsText,
                  bottomColor: const Color(0xFFD0902D),
                  isDark: isDark,
                ),
                right: MonthlyMini(
                  top: "—",
                  bottom: " ",
                  bottomColor: const Color(0xFFB54A3A),
                  isDark: isDark,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}


class MonthlyRow extends StatelessWidget {
  final Widget left;
  final Widget right;

  const MonthlyRow({
    super.key,
    required this.left,
    required this.right,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(child: left),
        const SizedBox(width: 12),
        Expanded(child: right),
      ],
    );
  }
}

class MonthlyMini extends StatelessWidget {
  final String top;
  final String bottom;
  final Color bottomColor;
  final bool isDark;

  const MonthlyMini({
    super.key,
    required this.top,
    required this.bottom,
    required this.bottomColor,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.grey[200],
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(isDark ? 0.2 : 0.1),
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            top,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w900,
              color: isDark ? Colors.white : Colors.black87,
            ),
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              bottom,
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: bottomColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}