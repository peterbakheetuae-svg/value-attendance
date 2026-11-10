import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/attendance_report_monthly_api.dart';
import '../../services/jph_bridge.dart';
import '../../services/api_service.dart';
import '../../services/attendance_report_daily_expanded_api.dart'; // 🔥 استيراد API الجديد
import '../../services/employee_list_api.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import 'attendance_filters.dart';
import 'attendance_monthly_section.dart';
import 'attendance_expandable_cards.dart'; // 🔥 استيراد البطاقات القابلة للطي
import 'attendance_widgets.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/payslip_pdf.dart';
import '../../widgets/glass_dialog.dart';

class AttendanceReportPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  /// open straight on one employee's monthly report (e.g. from the salaries list)
  final String? initialEmployeeId;
  final int? initialMonth;
  final int? initialYear;

  const AttendanceReportPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
    this.initialEmployeeId,
    this.initialMonth,
    this.initialYear,
  });

  @override
  State<AttendanceReportPage> createState() => _AttendanceReportPageState();
}

class _AttendanceReportPageState extends State<AttendanceReportPage> {
  bool isMonthly = true;
  int selMonth = DateTime.now().month;
  int selYear = DateTime.now().year;
  DateTime rangeStart = DateTime.now().subtract(const Duration(days: 30));
  DateTime rangeEnd = DateTime.now();
  bool loading = true;
  String? errorMessage;
  Map<String, dynamic> monthly = {};
  List<Map<String, dynamic>> daily = [];

  // 🔥 متغيرات جديدة للموظفين
  List<Map<String, dynamic>> employees = [];
  String? selectedUid;
  String? selectedEmployeeName;
  bool loadingEmployees = true;

  // 🔥 خريطة لتتبع حالة البطاقات المفتوحة/المغلقة
  final Map<String, bool> _expandedCards = {};

  // Cache
  final Map<String, int> _intCache = {};
  final Map<String, double> _doubleCache = {};
  final Map<String, String> _stringCache = {};

  @override
  void initState() {
    super.initState();
    if (widget.initialMonth != null) selMonth = widget.initialMonth!;
    if (widget.initialYear != null) selYear = widget.initialYear!;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      loadEmployees().then((_) {
        if (selectedUid != null) {
          loadMonthlyReport();
        }
      });
    });
  }

  /// Managers / HR choose whose report to see; a plain employee only ever sees his own.
  bool get _picksEmployee =>
      ApiService.can('attendance.read_all') || ApiService.can('attendance.read_team') || ApiService.can('report.read_all') || ApiService.can('report.read_team');

  // 🔥 دالة تحميل قائمة الموظفين
  Future<void> loadEmployees() async {
    if (!mounted) return;

    setState(() {
      loadingEmployees = true;
      errorMessage = null;
    });

    try {
      final res = await EmployeeListApi.fetch();

      if (!mounted) return;

      if (res["success"] == true) {
        setState(() {
          employees = List<Map<String, dynamic>>.from(res["employees"] ?? []);
          // a team manager (e.g. مدير المبيعات) sees only his team members who are on duty — not those who left / were settled
          if (!ApiService.can('employee.read_all')) {
            final me = JphBridge.myId;
            employees = employees.where((e) => '${e["uid"]}' == me || '${e["id"]}' == me || '${e["status"]}' == 'على رأس العمل').toList();
          }

          // 🔥 إذا كانت القائمة غير فارغة، نختار أول موظف افتراضيًا
          if (employees.isNotEmpty) {
            final wanted = widget.initialEmployeeId == null
                ? null
                : employees.where((e) => '${e["uid"]}' == widget.initialEmployeeId).firstOrNull;
            final pick = wanted ?? employees[0];
            selectedUid = pick["uid"];
            selectedEmployeeName = pick["name"];
          }
          loadingEmployees = false;
        });
      } else {
        setState(() {
          employees = [];
          loadingEmployees = false;
          errorMessage = res["message"] ?? AppLocalizations.of(context!, 'failed_to_load');
        });
      }
    } catch (e) {
      setState(() {
        employees = [];
        loadingEmployees = false;
        errorMessage = "${AppLocalizations.of(context!, 'connection_error')}: ${e.toString()}";
      });
    }
  }

  // ================== Helper Functions ==================
  int _safeToInt(dynamic value) {
    final key = value.toString();
    if (_intCache.containsKey(key)) return _intCache[key]!;

    int result = 0;
    if (value == null) result = 0;
    else if (value is int) result = value;
    else if (value is double) result = value.toInt();
    else if (value is String) {
      final doubleValue = _safeToDouble(value);
      result = doubleValue.toInt();
    }

    _intCache[key] = result;
    return result;
  }

  double _safeToDouble(dynamic value) {
    final key = value.toString();
    if (_doubleCache.containsKey(key)) return _doubleCache[key]!;

    double result = 0.0;
    try {
      if (value == null) result = 0.0;
      else if (value is double) result = value;
      else if (value is int) result = value.toDouble();
      else if (value is String) {
        String text = value.toString().trim();
        if (text.isEmpty) return 0.0;

        // معالجة الأرقام العربية والفارسية
        const arabicDigits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
        const persianDigits = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

        for (int i = 0; i < arabicDigits.length; i++) {
          text = text.replaceAll(arabicDigits[i], i.toString());
        }
        for (int i = 0; i < persianDigits.length; i++) {
          text = text.replaceAll(persianDigits[i], i.toString());
        }

        // معالجة الفواصل العشرية
        text = text
            .replaceAll('٫', '.')
            .replaceAll('،', '.')
            .replaceAll(',', '.');

        // إزالة أي أحرف غير رقمية باستثناء النقطة والعلامة السالبة
        final cleanText = text.replaceAll(RegExp(r'[^0-9\.\-]'), '');

        result = double.tryParse(cleanText) ?? 0.0;
      }
    } catch (e) {
      result = 0.0;
    }

    _doubleCache[key] = result;
    return result;
  }

  String _formatMoney(dynamic value) {
    final key = value.toString();
    if (_stringCache.containsKey('money_$key')) return _stringCache['money_$key']!;

    String result;
    try {
      final numValue = _safeToDouble(value);

      // ✅ عرض جميع القيم المالية بمنزلتين عشريتين
      final formatted = numValue.toStringAsFixed(2);
      final parts = formatted.split('.');
      final integerPart = parts[0];
      final decimalPart = parts.length > 1 ? parts[1] : '00';

      // إضافة فواصل الآلاف للأرقام الكبيرة
      if (numValue.abs() >= 1000) {
        String withSeparators = '';
        int count = 0;

        // من اليمين لليسار لإضافة الفواصل
        for (int i = integerPart.length - 1; i >= 0; i--) {
          withSeparators = integerPart[i] + withSeparators;
          count++;
          if (count == 3 && i > 0) {
            withSeparators = ',$withSeparators';
            count = 0;
          }
        }

        // عرض بدون .00 إذا كانت الأجزاء العشرية صفر
        result = decimalPart == '00' ? withSeparators : '$withSeparators.$decimalPart';
      } else {
        // عرض بدون .00 إذا كانت الأجزاء العشرية صفر
        result = decimalPart == '00' ? integerPart : formatted;
      }
    } catch (e) {
      result = '0.00';
    }

    _stringCache['money_$key'] = result;
    return result;
  }

  String _formatOvertime(dynamic value) {
    final key = value.toString();
    if (_stringCache.containsKey('overtime_$key')) return _stringCache['overtime_$key']!;

    String result;
    if (value == null) {
      result = '0:00';
    } else if (value is String) {
      if (value.contains(':')) {
        result = value;
      } else {
        final hours = _safeToDouble(value);
        if (hours % 1 == 0) {
          result = '${hours.toInt()}:00';
        } else {
          final wholeHours = hours.toInt();
          final minutes = ((hours - wholeHours) * 60).round();
          result = '$wholeHours:${minutes.toString().padLeft(2, '0')}';
        }
      }
    } else if (value is int) {
      result = '$value:00';
    } else if (value is double) {
      final wholeHours = value.toInt();
      final minutes = ((value - wholeHours) * 60).round();
      result = '$wholeHours:${minutes.toString().padLeft(2, '0')}';
    } else {
      result = '0:00';
    }

    _stringCache['overtime_$key'] = result;
    return result;
  }

  // ================== API Calls ==================
  Future<void> loadMonthlyReport() async {
    if (!mounted || selectedUid == null) return;

    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {
      final res = await AttendanceReportMonthlyApi.fetch(
        uid: selectedUid!, // 🔥 استخدام الموظف المختار
        year: selYear,
        month: _monthNameAr(selMonth),
      );

      if (!mounted) return;

      if (res["success"] == true) {
        setState(() {
          monthly = (res["report"] ?? {}) as Map<String, dynamic>;
          loading = false;
        });
      } else {
        setState(() {
          monthly = {};
          loading = false;
          errorMessage = res["message"] ?? AppLocalizations.of(context!, 'failed_to_load');
        });

        if (mounted) {
          ScaffoldMessenger.of(context!).showSnackBar(
            SnackBar(
              content: Text(errorMessage!),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        monthly = {};
        loading = false;
        errorMessage = "${AppLocalizations.of(context!, 'connection_error')}: ${e.toString()}";
      });

      if (mounted) {
        ScaffoldMessenger.of(context!).showSnackBar(
          SnackBar(
            content: Text(errorMessage!),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> loadDailyReport() async {
    if (!mounted || selectedUid == null) return;

    setState(() {
      loading = true;
      errorMessage = null;
    });

    try {
      final res = await AttendanceReportDailyExpandedApi.fetch(
        uid: selectedUid!, // 🔥 استخدام الموظف المختار
        from: _fmtDateIso(rangeStart),
        to: _fmtDateIso(rangeEnd),
      );

      if (!mounted) return;

      if (res["success"] == true) {
        setState(() {
          daily = List<Map<String, dynamic>>.from(res["days"] ?? []);

          // 🔥 تهيئة حالة جميع البطاقات كمطوية (false)
          _expandedCards.clear();
          for (var day in daily) {
            if (day['cardId'] != null) {
              _expandedCards[day['cardId']] = false;
            }
          }

          loading = false;
        });
      } else {
        setState(() {
          daily = [];
          loading = false;
          errorMessage = res["message"] ?? AppLocalizations.of(context!, 'failed_to_load');
        });

        if (mounted) {
          ScaffoldMessenger.of(context!).showSnackBar(
            SnackBar(
              content: Text(errorMessage!),
              backgroundColor: Colors.redAccent,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        daily = [];
        loading = false;
        errorMessage = "${AppLocalizations.of(context!, 'connection_error')}: ${e.toString()}";
      });

      if (mounted) {
        ScaffoldMessenger.of(context!).showSnackBar(
          SnackBar(
            content: Text(errorMessage!),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// المدير / HR / المالك correct someone else's times (never their own); the edit is recorded with their name.
  bool get _canCorrect =>
      ApiService.can('attendance.correct') && selectedUid != null && selectedUid != widget.uid;

  Future<void> _editDay(Map<String, dynamic> day, bool isDark) async {
    TimeOfDay? parse(Object? v) {
      final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch('${v ?? ''}');
      return m == null ? null : TimeOfDay(hour: int.parse(m.group(1)!), minute: int.parse(m.group(2)!));
    }
    String fmt(TimeOfDay? t) => t == null ? '' : '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    TimeOfDay? tIn = parse(day['startTime']) ?? const TimeOfDay(hour: 9, minute: 0);
    TimeOfDay? tOut = parse(day['endTime']);
    final reason = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(builder: (c, setS) {
          Widget pick(String label, TimeOfDay? v, ValueChanged<TimeOfDay?> on, {bool clearable = false}) => ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.access_time_rounded),
                title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: Text(v == null ? 'مش متسجل' : fmt(v), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                trailing: clearable && v != null ? IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => setS(() => on(null))) : null,
                onTap: () async {
                  final t = await showTimePicker(context: c, initialTime: v ?? const TimeOfDay(hour: 17, minute: 0));
                  if (t != null) setS(() => on(t));
                },
              );
          return GlassAlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
            title: Text('تعديل مواعيد ${day['workDate'] ?? day['date'] ?? ''}', textAlign: TextAlign.center,
                style: const TextStyle(fontWeight: FontWeight.w800)),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(selectedEmployeeName ?? '', style: const TextStyle(fontWeight: FontWeight.w700)),
              pick('وقت الحضور', tIn, (t) => tIn = t),
              pick('وقت الانصراف', tOut, (t) => tOut = t, clearable: true),
              TextField(controller: reason, decoration: const InputDecoration(labelText: 'سبب التعديل (اختياري)')),
              const SizedBox(height: 8),
              const Text('المواعيد الأصلية بتفضل محفوظة، والتعديل بيتسجل باسمك.', style: TextStyle(fontSize: 12, color: Colors.grey)),
            ]),
            actions: [
              TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('إلغاء')),
              FilledButton(onPressed: tIn == null ? null : () => Navigator.pop(c, true), child: const Text('حفظ')),
            ],
          );
        }),
      ),
    );
    if (ok != true || !mounted) return;
    final r = await ApiService.post({
      'action': 'attendance_correct', 'uid': selectedUid, 'workDate': day['workDate'] ?? day['date'],
      'checkIn': fmt(tIn), 'checkOut': fmt(tOut), 'reason': reason.text,
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? (r['success'] == true ? 'تم ✅' : 'حصلت مشكلة')}'),
      backgroundColor: r['success'] == true ? Colors.green : Colors.red,
    ));
    if (r['success'] == true) loadDailyReport();
  }

  // 🔥 دالة لتغيير حالة البطاقة
  void _toggleCard(String cardId) {
    setState(() {
      _expandedCards[cardId] = !(_expandedCards[cardId] ?? false);
    });
  }

  // ================== UI Build ==================
  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        // 🔥 استخدام الترجمة
        final attendanceReportTitle = AppLocalizations.of(context, 'attendance_report');
        final monthlyReportText = AppLocalizations.of(context, 'monthly_report');
        final dailyReportText = AppLocalizations.of(context, 'daily_report');
        final filterText = AppLocalizations.of(context, 'filter');
        final loadingText = AppLocalizations.of(context, 'loading_data');
        final noMonthlyDataText = AppLocalizations.of(context, 'no_monthly_data');
        final noDailyDataText = AppLocalizations.of(context, 'no_daily_data');
        final errorText = AppLocalizations.of(context, 'error_occurred');
        final retryText = AppLocalizations.of(context, 'retry');
        final selectEmployeeText = AppLocalizations.of(context, 'select_employee');

        return Directionality(
          textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
          child: AppBackground(
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                bottom: false, // the content scrolls under the glass bar
                child: Column(
                  children: [
                    Header(
                      onBack: () => Navigator.pop(context),
                      onFilter: () => _openFilter(context, appController.isDark),
                      onPrint: isMonthly && monthly.isNotEmpty && ApiService.can('employee.salary_read')
                          ? () async {
                              try {
                                await printPayslip(monthly: monthly, employeeName: selectedEmployeeName ?? '',
                                    monthLabel: '${_monthNameAr(selMonth)} $selYear');
                              } catch (e) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('تعذّر الطباعة: $e'), backgroundColor: Colors.red));
                                }
                              }
                            }
                          : null,
                      isRTL: appController.isRTL,
                      isDark: appController.isDark,
                      title: attendanceReportTitle,
                    ),

                    // اختيار الموظف — للمديرين والـ HR بس؛ الموظف بيشوف تقريره هو من غير الخانة
                    if (_picksEmployee) EmployeeDropdown(
                      employees: employees,
                      selectedUid: selectedUid,
                      selectedEmployeeName: selectedEmployeeName,
                      loading: loadingEmployees,
                      onChanged: (String? newUid, String? newName) {
                        setState(() {
                          selectedUid = newUid;
                          selectedEmployeeName = newName;
                        });
                        if (isMonthly) {
                          loadMonthlyReport();
                        } else {
                          loadDailyReport();
                        }
                      },
                      isDark: appController.isDark,
                      selectEmployeeText: selectEmployeeText,
                    ),

                    if (_picksEmployee) const SizedBox(height: 14),

                    // 🔥 تم إزالة PeriodBar و TopStats بناءً على طلبك

                    Tabs(
                      isMonthly: isMonthly,
                      onTabChange: (value) {
                        setState(() => isMonthly = value);
                        if (value && monthly.isEmpty) loadMonthlyReport();
                        if (!value && daily.isEmpty) loadDailyReport();
                      },
                      isDark: appController.isDark,
                      tab1Text: monthlyReportText,
                      tab2Text: dailyReportText,
                    ),
                    const SizedBox(height: 14),
                    Expanded(
                      child: _buildContent(
                        isMonthly: isMonthly,
                        loading: loading,
                        errorMessage: errorMessage,
                        monthly: monthly,
                        daily: daily,
                        isDark: appController.isDark,
                        onReload: () => isMonthly ? loadMonthlyReport() : loadDailyReport(),
                        safeToInt: _safeToInt,
                        formatMoney: _formatMoney,
                        formatOvertime: _formatOvertime,
                        loadingText: loadingText,
                        noMonthlyDataText: noMonthlyDataText,
                        noDailyDataText: noDailyDataText,
                        errorText: errorText,
                        retryText: retryText,
                        context: context,
                      ),
                    ),
                  ],
                ),
              ),
              // الفلتر فوق في الهيدر؛ وتحت شريط التنقل زي الإعدادات والملف الشخصي
              extendBody: true,
              bottomNavigationBar: GlassBottomNav(
                currentIndex: 1,
                onTap: (index) => AppNav.go(context, index, current: 1, uid: widget.uid, name: widget.name, role: widget.role),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent({
    required bool isMonthly,
    required bool loading,
    required String? errorMessage,
    required Map<String, dynamic> monthly,
    required List<Map<String, dynamic>> daily,
    required bool isDark,
    required VoidCallback onReload,
    required int Function(dynamic) safeToInt,
    required String Function(dynamic) formatMoney,
    required String Function(dynamic) formatOvertime,
    required String loadingText,
    required String noMonthlyDataText,
    required String noDailyDataText,
    required String errorText,
    required String retryText,
    required BuildContext context,
  }) {
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
              loadingText,
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
      return _buildErrorState(errorMessage!, isDark, onReload, errorText, retryText);
    }

    if (errorMessage != null && !isMonthly && daily.isEmpty) {
      return _buildErrorState(errorMessage!, isDark, onReload, errorText, retryText);
    }

    if (isMonthly && monthly.isEmpty) {
      return _buildEmptyState(noMonthlyDataText, isDark, AppLocalizations.of(context, 'no_data'));
    }

    if (!isMonthly && daily.isEmpty) {
      return _buildEmptyState(noDailyDataText, isDark, AppLocalizations.of(context, 'no_data'));
    }

    if (isMonthly) {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 120),
        child: MonthlySection(
          canPrint: ApiService.can('employee.salary_read'),
          // money boxes only for those who read salaries (or his own report); a team manager sees the first six only
          showMoney: ApiService.can('employee.salary_read') || selectedUid == JphBridge.myId || selectedUid == JphBridge.myCode,
          employeeName: selectedEmployeeName ?? '',
          monthLabel: '${_monthNameAr(selMonth)} $selYear',
          monthly: monthly,
          isDark: isDark,
          safeToInt: safeToInt,
          formatMoney: formatMoney,
          formatOvertime: formatOvertime,
        ),
      );
    } else {
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 120),
        child: AttendanceExpandableCards(
          days: daily,
          isDark: isDark,
          expandedCards: _expandedCards,
          onToggle: _toggleCard,
          onEdit: _canCorrect ? (d) => _editDay(d, isDark) : null,
        ),
      );
    }
  }

  Widget _buildErrorState(
      String message,
      bool isDark,
      VoidCallback onRetry,
      String errorText,
      String retryText,
      ) {
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
              errorText,
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
                retryText,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(String message, bool isDark, String noDataText) {
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
              noDataText,
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
      ),
    );
  }

  void _openFilter(BuildContext context, bool isDark) {
    if (selectedUid == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppLocalizations.of(context, 'select_employee_first')),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }

    if (isMonthly) {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (BuildContext sheetContext) {
          return MonthYearSheet(
            tmpMonth: selMonth,
            tmpYear: selYear,
            isDark: isDark,
            onApply: (month, year) {
              setState(() {
                selMonth = month;
                selYear = year;
                isMonthly = true;
              });
              Navigator.pop(sheetContext);
              loadMonthlyReport();
            },
          );
        },
      );
    } else {
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (BuildContext sheetContext) {
          return RangeSheet(
            tmpStart: rangeStart,
            tmpEnd: rangeEnd,
            isDark: isDark,
            onApply: (start, end) {
              setState(() {
                rangeStart = start;
                rangeEnd = end;
                isMonthly = false;
              });
              Navigator.pop(sheetContext);
              loadDailyReport();
            },
          );
        },
      );
    }
  }

  // ================== Helper Functions ==================
  String _fmtDateIso(DateTime d) {
    final yy = d.year.toString();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return "$yy-$mm-$dd";
  }

  String _monthNameAr(int m) {
    const names = [
      "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
      "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"
    ];
    return names[(m - 1).clamp(0, 11)];
  }
}