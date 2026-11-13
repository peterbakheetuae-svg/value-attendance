import '../widgets/side_sheet.dart';
import 'dart:ui' as ui;
import 'dart:ui';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../services/leave_request_api.dart';
import '../widgets/app_background.dart';
import '../theme/app_colors.dart';
import '../l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import 'attendance/attendance_filters.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_ui.dart';

class LeaveSummaryPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const LeaveSummaryPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<LeaveSummaryPage> createState() => _LeaveSummaryPageState();
}

class _LeaveSummaryPageState extends State<LeaveSummaryPage> {
  bool _loading = true;
  bool _hasError = false;
  String _errorMessage = '';
  List<dynamic> _leaveRequests = [];
  List<dynamic> _filteredRequests = [];
  Map<String, dynamic> _stats = {
    'pending': 0,
    'approved': 0,
    'rejected': 0,
    'cancelled': 0,
  };

  // Filter variables - Now only monthly
  int _filterMonth = DateTime.now().month;
  int _filterYear = DateTime.now().year;
  String _statusFilter = 'all';

  // For searching
  final TextEditingController _searchController = TextEditingController();
  FocusNode _searchFocusNode = FocusNode();
  bool _isSearching = false;

  // To track expanded state of each card
  Map<String, bool> _expandedCards = {};

  @override
  void initState() {
    super.initState();
    _loadLeaveRequests();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _loadLeaveRequests() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _hasError = false;
      _errorMessage = '';
    });

    try {
      print('🚀 بدء تحميل جميع طلبات الإجازة...');
      print('👤 دور المستخدم: ${widget.role}');
      print('👤 UID: ${widget.uid}');

      // استخدام API واحد لجلب جميع الطلبات بدون تمييز
      Map<String, dynamic> res = await LeaveRequestApi.getAllLeaveRequests();

      print('📊 استجابة API: ${res.toString()}');

      if (!mounted) return;

      if (res["success"] == true) {
        print('✅ تم تحميل البيانات بنجاح');
        print('📊 عدد الطلبات: ${res["requests"]?.length ?? 0}');
        print('📊 الإحصائيات: ${res["stats"]}');

        final requests = List<dynamic>.from(res["requests"] ?? []);
        final stats = Map<String, dynamic>.from(res["stats"] ?? {
          'pending': 0,
          'approved': 0,
          'rejected': 0,
          'cancelled': 0,
        });

        // تأكد من أن كل طلب يحتوي على الحقول المطلوبة
        final formattedRequests = requests.map((request) {
          final Map<String, dynamic> req = Map<String, dynamic>.from(request);

          // تأكد من وجود الحقول الأساسية
          if (!req.containsKey('status') || req['status'] == null) {
            req['status'] = 'قيد المراجعة';
          }

          if (!req.containsKey('leaveType') || req['leaveType'] == null) {
            req['leaveType'] = 'غير محدد';
          }

          if (!req.containsKey('days') || req['days'] == null) {
            req['days'] = 0;
          }

          if (!req.containsKey('employeeName') || req['employeeName'] == null) {
            req['employeeName'] = 'غير معروف';
          }

          if (!req.containsKey('reason') || req['reason'] == null) {
            req['reason'] = 'لا يوجد سبب';
          }

          return req;
        }).toList();

        // Initialize expanded state for all cards
        final newExpandedCards = <String, bool>{};
        for (var request in formattedRequests) {
          final id = request['id']?.toString() ?? request['requestId']?.toString() ?? '';
          if (id.isNotEmpty) {
            newExpandedCards[id] = _expandedCards[id] ?? false;
          }
        }

        setState(() {
          _leaveRequests = formattedRequests;
          _filteredRequests = List.from(formattedRequests);
          _stats = stats;
          _loading = false;
          _expandedCards = newExpandedCards;
        });

        print('✅ تم تحميل ${_leaveRequests.length} طلب');
        print('📊 الإحصائيات: $_stats');
      } else {
        print('❌ فشل في جلب البيانات: ${res["message"]}');
        setState(() {
          _hasError = true;
          _errorMessage = res["message"]?.toString() ?? "فشل في جلب البيانات";
          _loading = false;
        });
      }
    } catch (e) {
      print('❌ خطأ غير متوقع في _loadLeaveRequests: $e');
      if (!mounted) return;

      setState(() {
        _hasError = true;
        _errorMessage = "حدث خطأ في الاتصال بالخادم: $e";
        _loading = false;
      });
    }
  }

  void _applyFilters() {
    try {
      List<dynamic> filtered = List.from(_leaveRequests);

      // Apply status filter
      if (_statusFilter != 'all') {
        filtered = filtered.where((request) {
          final status = request['status']?.toString().trim() ?? '';
          return status == _statusFilter;
        }).toList();
      }

      // Apply date filter (monthly only)
      filtered = filtered.where((request) {
        try {
          final dateStr = request['fromDate'] ?? request['startDate'] ?? '';
          if (dateStr.isEmpty) return false;
          final date = DateTime.parse(dateStr);
          return date.month == _filterMonth && date.year == _filterYear;
        } catch (e) {
          return false;
        }
      }).toList();

      // Apply search filter
      if (_searchController.text.isNotEmpty) {
        final searchTerm = _searchController.text.toLowerCase();
        filtered = filtered.where((request) {
          final employeeName = request['employeeName']?.toString().toLowerCase() ?? '';
          final reason = request['reason']?.toString().toLowerCase() ?? '';
          final leaveType = request['leaveType']?.toString().toLowerCase() ?? '';
          final employeeId = request['employeeId']?.toString().toLowerCase() ?? '';

          return employeeName.contains(searchTerm) ||
              reason.contains(searchTerm) ||
              leaveType.contains(searchTerm) ||
              employeeId.contains(searchTerm);
        }).toList();
      }

      setState(() {
        _filteredRequests = filtered;
        _updateFilteredStats();
      });
    } catch (e) {
      print('❌ خطأ في تطبيق الفلاتر: $e');
    }
  }

  void _updateFilteredStats() {
    try {
      int pending = 0;
      int approved = 0;
      int rejected = 0;
      int cancelled = 0;

      for (var request in _filteredRequests) {
        final status = request['status']?.toString().trim() ?? '';
        switch (status) {
          case 'قيد المراجعة':
            pending++;
            break;
          case 'مقبؤل':
            approved++;
            break;
          case 'مرفوض':
            rejected++;
            break;
          case 'ملغي':
            cancelled++;
            break;
          case 'ملغى': // حالة بديلة قد تأتي من API
            cancelled++;
            break;
        }
      }

      setState(() {
        _stats = {
          'pending': pending,
          'approved': approved,
          'rejected': rejected,
          'cancelled': cancelled,
        };
      });
    } catch (e) {
      print('❌ خطأ في تحديث الإحصائيات: $e');
    }
  }

  void _resetFilters() {
    setState(() {
      _filterMonth = DateTime.now().month;
      _filterYear = DateTime.now().year;
      _statusFilter = 'all';
      _searchController.clear();
      _filteredRequests = List.from(_leaveRequests);
      _updateFilteredStats();
    });
  }

  Future<void> _showFilterSheet() async {
    final appController = Provider.of<AppController>(context, listen: false);
    final isDark = appController.isDark;

    showAppSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Container(
              margin: const EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                  color: isDark ? const Color(0xFF262624) : Colors.white,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SheetHeader(
                        title: 'تصفية طلبات الإجازة',
                        icon: Icons.filter_alt_rounded,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 14),

                      // Monthly Picker Section
                      Container(
                        height: 260,
                        decoration: Glass.panel(isDark, r: 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                children: [
                                  const SizedBox(height: 12),
                                  Text(
                                    'السنة',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: isDark ? Colors.white : Colors.black,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: CupertinoPicker(
                                      scrollController: FixedExtentScrollController(
                                        initialItem: _getYearIndex(_filterYear),
                                      ),
                                      itemExtent: 44,
                                      onSelectedItemChanged: (i) {
                                        setState(() {
                                          _filterYear = _getYears()[i];
                                        });
                                      },
                                      children: [
                                        for (final y in _getYears())
                                          Center(
                                            child: Text(
                                              "$y",
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w900,
                                                color: (y == _filterYear)
                                                    ? (isDark ? AppColors.primaryLight : AppColors.primary)
                                                    : (isDark ? Colors.white : Colors.black),
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
                              color: isDark ? AppColors.primaryLight.withOpacity(0.15) : AppColors.primary.withOpacity(0.15),
                            ),
                            Expanded(
                              child: Column(
                                children: [
                                  const SizedBox(height: 12),
                                  Text(
                                    'الشهر',
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w800,
                                      color: isDark ? Colors.white : Colors.black,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Expanded(
                                    child: CupertinoPicker(
                                      scrollController: FixedExtentScrollController(
                                        initialItem: _filterMonth - 1,
                                      ),
                                      itemExtent: 44,
                                      onSelectedItemChanged: (i) {
                                        setState(() => _filterMonth = i + 1);
                                      },
                                      children: [
                                        for (final m in _getMonths())
                                          Center(
                                            child: Text(
                                              _monthNameAr(m),
                                              style: TextStyle(
                                                fontSize: 18,
                                                fontWeight: FontWeight.w900,
                                                color: (m == _filterMonth)
                                                    ? (isDark ? AppColors.primaryLight : AppColors.primary)
                                                    : (isDark ? Colors.white : Colors.black),
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

                      const SizedBox(height: 14),

                      // Status Dropdown
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: Glass.panel(isDark, r: 18),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'حالة الطلب:',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              decoration: Glass.panel(isDark, r: 14),
                              child: DropdownButton<String>(
                                value: _statusFilter,
                                isExpanded: true,
                                underline: const SizedBox(),
                                icon: Icon(
                                  Icons.arrow_drop_down_rounded,
                                  color: isDark ? AppColors.primaryLight : AppColors.primary,
                                  size: 28,
                                ),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                                dropdownColor: isDark ? const Color(0xFF35342F) : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                onChanged: (String? newValue) {
                                  setState(() {
                                    _statusFilter = newValue!;
                                  });
                                },
                                items: <String>['all', 'قيد المراجعة', 'مقبؤل', 'مرفوض', 'ملغي']
                                    .map<DropdownMenuItem<String>>((String value) {
                                  String displayText;
                                  switch (value) {
                                    case 'all':
                                      displayText = 'الكل';
                                      break;
                                    case 'قيد المراجعة':
                                      displayText = 'قيد المراجعة';
                                      break;
                                    case 'مقبؤل':
                                      displayText = 'مقبؤل';
                                      break;
                                    case 'مرفوض':
                                      displayText = 'مرفوض';
                                      break;
                                    case 'ملغي':
                                      displayText = 'ملغي';
                                      break;
                                    default:
                                      displayText = value;
                                  }
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(displayText),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Filter Actions
                      _SheetActions(
                        onApply: () {
                          _applyFilters();
                          Navigator.pop(context);
                        },
                        onCancel: () {
                          _resetFilters();
                          Navigator.pop(context);
                        },
                        applyText: 'تطبيق',
                        cancelText: 'إعادة التعيين',
                        isDark: isDark,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  List<int> _getYears() {
    return List.generate(6, (i) => DateTime.now().year - 2 + i);
  }

  int _getYearIndex(int year) {
    final years = _getYears();
    return years.indexOf(year).clamp(0, years.length - 1);
  }

  List<int> _getMonths() {
    return List.generate(12, (i) => i + 1);
  }

  String _monthNameAr(int m) {
    const names = [
      "يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
      "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"
    ];
    return names[(m - 1).clamp(0, 11)];
  }

  String _formatDate(String dateStr) {
    try {
      final date = DateTime.parse(dateStr);
      return DateFormat('yyyy-MM-dd').format(date);
    } catch (e) {
      return dateStr;
    }
  }

  Color _getStatusColor(String status) {
    switch (status.toLowerCase()) {
      case 'مقبؤل':
        return const Color(0xFF4FCF73);
      case 'مرفوض':
        return const Color(0xFFFF7D6E);
      case 'قيد المراجعة':
        return const Color(0xFFF7A928);
      case 'ملغي':
      case 'ملغى':
        return const Color(0xFF8F8B84);
      default:
        return const Color(0xFF8F8B84);
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status.toLowerCase()) {
      case 'مقبؤل':
        return Icons.check_circle;
      case 'مرفوض':
        return Icons.cancel;
      case 'قيد المراجعة':
        return Icons.pending;
      case 'ملغي':
      case 'ملغى':
        return Icons.block_rounded;
      default:
        return Icons.question_mark;
    }
  }

  String _getStatusText(String status) {
    return status;
  }

  Future<void> _updateLeaveStatus(
      String requestId, int index, String status) async {
    final request = _filteredRequests[index];
    final currentStatus = request['status']?.toString() ?? '';

    final appController = Provider.of<AppController>(context, listen: false);
    final isRTL = appController.isRTL;

    String actionText = '';
    Color actionColor = const Color(0xFF4FCF73);

    switch (status) {
      case 'approved':
        actionText = 'موافقة';
        actionColor = const Color(0xFF4FCF73);
        break;
      case 'rejected':
        actionText = 'رفض';
        actionColor = const Color(0xFFFF7D6E);
        break;
      case 'cancelled':
        actionText = 'إلغاء';
        actionColor = const Color(0xFF8F8B84);
        break;
    }

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: GlassAlertDialog(
          backgroundColor:
          appController.isDark ? Ar.grey[900] : Colors.white,
          title: Text(
            'تأكيد $actionText',
            style: TextStyle(
              color: appController.isDark ? Colors.white : Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            'هل أنت متأكد من $actionText طلب الإجازة؟',
            style: TextStyle(
              color:
              appController.isDark ? Colors.white70 : Ar.grey[700],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                'إلغاء',
                style: TextStyle(
                  color: appController.isDark
                      ? Ar.info[300]
                      : Ar.info,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: actionColor,
                foregroundColor: Colors.white,
              ),
              child: Text('تأكيد $actionText'),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    setState(() {
      _loading = true;
    });

    try {
      Map<String, dynamic> result;

      if (status == 'approved') {
        result = await LeaveRequestApi.approveLeaveRequest(
            requestId, widget.uid);
      } else if (status == 'rejected') {
        result = await LeaveRequestApi.rejectLeaveRequest(
            requestId, widget.uid);
      } else {
        result = await LeaveRequestApi.cancelLeaveRequest(
          uid: widget.uid,
          requestId: requestId,
        );
      }

      if (!mounted) return;

      if (result["success"] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle, color: Colors.white),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    result["message"] ?? 'تم تحديث حالة الطلب بنجاح',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            backgroundColor: const Color(0xFF2FA65A),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 3),
          ),
        );

        // Update local data
        setState(() {
          // Update in filtered list
          String newStatus = '';
          if (status == 'approved') {
            newStatus = 'مقبؤل';
          } else if (status == 'rejected') {
            newStatus = 'مرفوض';
          } else {
            newStatus = 'ملغي';
          }

          _filteredRequests[index]['status'] = newStatus;

          // Update in main list
          final requestIdToUpdate =
              _filteredRequests[index]['id'] ?? _filteredRequests[index]['requestId'];
          final mainIndex = _leaveRequests.indexWhere((req) =>
          (req['id'] ?? req['requestId']) == requestIdToUpdate);
          if (mainIndex != -1) {
            _leaveRequests[mainIndex]['status'] = newStatus;
          }

          // Update statistics
          _updateFilteredStats();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result["message"] ?? 'فشل في تحديث حالة الطلب'),
            backgroundColor: const Color(0xFFE5604F),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('حدث خطأ أثناء التحديث: $e'),
          backgroundColor: const Color(0xFFE5604F),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Widget _buildSearchBar(bool isDark, Color textColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: Glass.panel(isDark, r: 16),
        child: Row(
          children: [
            Icon(
              Icons.search,
              color: isDark ? Colors.white70 : Ar.grey.shade600,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocusNode,
                onChanged: (value) {
                  _applyFilters();
                },
                decoration: InputDecoration(
                  hintText: 'بحث باسم الموظف، السبب، النوع...',
                  hintStyle: TextStyle(
                    color: isDark ? Colors.white60 : Ar.grey.shade600,
                  ),
                  border: InputBorder.none,
                ),
                style: TextStyle(
                  color: textColor,
                  fontSize: 14,
                ),
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                onPressed: () {
                  _searchController.clear();
                  _applyFilters();
                },
                icon: Icon(
                  Icons.clear,
                  color: isDark ? Colors.white70 : Ar.grey.shade600,
                  size: 20,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        final primaryColor =
        isDark ? AppColors.primaryLight : AppColors.primary;
        final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark
            ? AppColors.onSurfaceVariantDark
            : AppColors.onSurfaceVariantLight;
        final cardColor =
        isDark ? Colors.white.withOpacity(0.15) : Colors.white;
        final dividerColor =
        isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300;

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Column(
                  children: [
                    // Header
                    Padding(
                      padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: Glass.panel(isDark, r: 14),
                              child: Icon(
                                isRTL
                                    ? Icons.arrow_forward_ios_rounded
                                    : Icons.arrow_back_ios_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'جميع طلبات الإجازات',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _showFilterSheet,
                            icon: Container(
                              width: 46,
                              height: 46,
                              decoration: Glass.panel(isDark, r: 14),
                              child: Icon(
                                Icons.filter_alt_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Search Bar
                    _buildSearchBar(isDark, textColor),

                    const SizedBox(height: 8),

                    // 4 مربعات إحصائية
                    _buildStatsSection(isDark),

                    // Filter Info
                    if (_statusFilter != 'all' || _searchController.text.isNotEmpty)
                      Padding(
                        padding:
                        const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Container(
                          padding:
                          const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                          decoration: BoxDecoration(
                            color: isDark
                                ? Ar.info.shade900.withOpacity(0.3)
                                : Ar.info.shade50,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.filter_alt_rounded,
                                size: 16,
                                color: isDark
                                    ? Ar.info.shade300
                                    : Ar.info.shade700,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _getFilterInfo(),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isDark
                                        ? Ar.info.shade300
                                        : Ar.info.shade700,
                                  ),
                                ),
                              ),
                              GestureDetector(
                                onTap: _resetFilters,
                                child: Text(
                                  'إلغاء',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: isDark
                                        ? Ar.info.shade300
                                        : Ar.info.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    const SizedBox(height: 8),

                    // قائمة الطلبات
                    Expanded(
                      child: _buildRequestsSection(
                        isDark: isDark,
                        isRTL: isRTL,
                        primaryColor: primaryColor,
                        textColor: textColor,
                        subduedTextColor: subduedTextColor,
                        cardColor: cardColor,
                        dividerColor: dividerColor,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  String _getFilterInfo() {
    List<String> filters = [];

    if (_statusFilter != 'all') {
      String statusText = '';
      switch (_statusFilter) {
        case 'قيد المراجعة':
          statusText = 'قيد المراجعة';
          break;
        case 'مقبؤل':
          statusText = 'مقبؤل';
          break;
        case 'مرفوض':
          statusText = 'مرفوض';
          break;
        case 'ملغي':
          statusText = 'ملغي';
          break;
        default:
          statusText = _statusFilter;
      }
      filters.add('الحالة: $statusText');
    }

    if (_searchController.text.isNotEmpty) {
      filters.add('بحث: ${_searchController.text}');
    }

    filters.add('التاريخ: ${_filterMonth}/${_filterYear}');

    return filters.join(' • ');
  }

  Widget _buildStatsSection(bool isDark) {
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            // قيد المراجعة
            Expanded(
              child: _buildStatCard(
                title: 'قيد المراجعة',
                count: _stats['pending'] ?? 0,
                icon: Icons.pending_rounded,
                iconColor: const Color(0xFFF7A928),
                bgColor: isDark
                    ? const Color(0xFFE65100).withOpacity(0.3)
                    : const Color(0xFFFFF3E0),
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 8),

            // المقبولة
            Expanded(
              child: _buildStatCard(
                title: 'المقبولة',
                count: _stats['approved'] ?? 0,
                icon: Icons.check_circle_rounded,
                iconColor: const Color(0xFF4FCF73),
                bgColor: isDark
                    ? const Color(0xFF1B5E20).withOpacity(0.3)
                    : const Color(0xFFE8F5E9),
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 8),

            // المرفوضة
            Expanded(
              child: _buildStatCard(
                title: 'المرفوضة',
                count: _stats['rejected'] ?? 0,
                icon: Icons.cancel_rounded,
                iconColor: const Color(0xFFFF7D6E),
                bgColor: isDark
                    ? const Color(0xFFB71C1C).withOpacity(0.3)
                    : const Color(0xFFFFEBEE),
                isDark: isDark,
              ),
            ),
            const SizedBox(width: 8),

            // الملغية
            Expanded(
              child: _buildStatCard(
                title: 'الملغية',
                count: _stats['cancelled'] ?? 0,
                icon: Icons.block_rounded,
                iconColor: const Color(0xFF8F8B84),
                bgColor: isDark
                    ? Ar.grey.withOpacity(0.3)
                    : Ar.grey.shade100,
                isDark: isDark,
              ),
            ),

          ],
            )
        );

    }

  Widget _buildRequestsSection({
    required bool isDark,
    required bool isRTL,
    required Color primaryColor,
    required Color textColor,
    required Color subduedTextColor,
    required Color cardColor,
    required Color dividerColor,
  }) {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: primaryColor),
            const SizedBox(height: 16),
            Text(
              'جاري تحميل طلبات الإجازة...',
              style: TextStyle(
                color: subduedTextColor,
                fontSize: 16,
              ),
            ),
          ],
        ),
      );
    }

    if (_hasError) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.error_outline_rounded,
              size: 64,
              color: const Color(0xFFFF7D6E),
            ),
            const SizedBox(height: 16),
            Text(
              _errorMessage,
              style: TextStyle(
                fontSize: 16,
                color: const Color(0xFFFF7D6E),
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: _loadLeaveRequests,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                padding:
                const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('إعادة المحاولة'),
            ),
          ],
        ),
      );
    }

    if (_filteredRequests.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.event_busy_rounded,
              size: 64,
              color: subduedTextColor,
            ),
            const SizedBox(height: 16),
            Text(
              'لا توجد طلبات إجازة',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: subduedTextColor,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _searchController.text.isNotEmpty || _statusFilter != 'all'
                  ? 'لم يتم العثور على نتائج مطابقة للبحث'
                  : 'قم بتقديم طلب إجازة أولاً',
              style: TextStyle(
                fontSize: 14,
                color: subduedTextColor,
              ),
            ),
            if (_searchController.text.isNotEmpty || _statusFilter != 'all')
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: ElevatedButton(
                  onPressed: _resetFilters,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryColor,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('إعادة تعيين الفلاتر'),
                ),
              ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLeaveRequests,
      color: primaryColor,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        itemCount: _filteredRequests.length,
        separatorBuilder: (context, index) => const SizedBox(height: 12),
        itemBuilder: (context, index) {
          final request = _filteredRequests[index];
          return _buildLeaveRequestCard(
            request: request,
            index: index,
            isDark: isDark,
            textColor: textColor,
            subduedTextColor: subduedTextColor,
            cardColor: cardColor,
            dividerColor: dividerColor,
          );
        },
      ),
    );
  }

  Widget _buildStatCard({
    required String title,
    required int count,
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: Glass.tile(isDark, r: 10),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Ar.grey.shade700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            count.toString(),
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w900,
              color: iconColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLeaveRequestCard({
    required Map<String, dynamic> request,
    required int index,
    required bool isDark,
    required Color textColor,
    required Color subduedTextColor,
    required Color cardColor,
    required Color dividerColor,
  }) {
    final rawStatus = request['status']?.toString() ?? 'قيد المراجعة';
    final statusText = _getStatusText(rawStatus);
    final statusColor = _getStatusColor(rawStatus);
    final statusIcon = _getStatusIcon(rawStatus);
    final isPending = rawStatus == 'قيد المراجعة';

    final imageUrl = request['image']?.toString();
    final hasImage = imageUrl != null &&
        imageUrl.isNotEmpty &&
        imageUrl != 'null' &&
        !imageUrl.contains('undefined') &&
        (imageUrl.startsWith('http://') || imageUrl.startsWith('https://'));

    final days = (request['days'] ?? request['totalDays'] ?? request['daysCount'] ?? 0)
        .toInt();
    final employeeName = request['employeeName']?.toString() ?? 'غير معروف';
    final employeeId = request['employeeId']?.toString() ?? '';

    final cardId = request['id']?.toString() ?? request['requestId']?.toString() ?? 'card_$index';
    final isExpanded = _expandedCards[cardId] ?? false;

    return GestureDetector(
      onTap: () {
        setState(() {
          _expandedCards[cardId] = !isExpanded;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: Glass.panel(isDark, r: 20),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
        // Header with status and days - ALWAYS VISIBLE
        Row(
        children: [
        // Status
        Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: statusColor.withOpacity(0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: statusColor.withOpacity(0.3)),
        ),
        child: Row(
          children: [
            Icon(statusIcon, size: 16, color: statusColor),
            const SizedBox(width: 6),
            Text(
              statusText,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: statusColor,
              ),
            ),
          ],
        ),
      ),
      const Spacer(),

      // Days count
      Text(
        '$days يوم',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w900,
          color: textColor,
        ),
      ),
      const SizedBox(width: 12),

      // Expand/Collapse icon
      Icon(
        isExpanded ? Icons.expand_less : Icons.expand_more,
        color: subduedTextColor,
        size: 24,
      ),
      ],
    ),

    const SizedBox(height: 12),

    // Employee Info - ALWAYS VISIBLE
    Row(
    children: [
    Icon(
    Icons.person_rounded,
    size: 18,
    color: subduedTextColor,
    ),
    const SizedBox(width: 8),
    Expanded(
    child: Text(
    employeeName,
    style: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: textColor,
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    ),
    ),
    ],
    ),

    const SizedBox(height: 8),

    // Leave Type - ALWAYS VISIBLE
    Row(
    children: [
    Icon(
    Icons.work_off_rounded,
    size: 18,
    color: subduedTextColor,
    ),
    const SizedBox(width: 8),
    Expanded(
    child: Text(
    request['leaveType']?.toString() ?? 'غير محدد',
    style: TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    color: textColor,
    ),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    ),
    ),
    ],
    ),

    const SizedBox(height: 12),

    // مين وافق لحد دلوقتي
    if ('${request['approvedBy'] ?? ''}'.isNotEmpty) ...[
    Row(children: [
    const Icon(Icons.verified_rounded, size: 18, color: Ar.green),
    const SizedBox(width: 8),
    Expanded(child: Text('وافق: ${request['approvedBy']}', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Ar.green))),
    ]),
    const SizedBox(height: 6),
    ],
    if (isPending && '${request['notes'] ?? ''}'.isNotEmpty) ...[
    Text('${request['notes']}', style: TextStyle(fontSize: 12.5, color: subduedTextColor)),
    const SizedBox(height: 8),
    ],

    // Action Buttons — only for the direct manager / general manager / HR at their stage (never the employee)
    if (isPending && request['canDecide'] == true) ...[
    Row(
    children: [
    Expanded(
    child: ElevatedButton(
    onPressed: () => _updateLeaveStatus(
    request['requestId']?.toString() ??
    request['id']?.toString() ??
    '',
    index,
    'approved'),
    style: ElevatedButton.styleFrom(
    backgroundColor: Ar.green.withOpacity(0.1),
    foregroundColor: Ar.green,
    elevation: 0,
    shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: Ar.green.withOpacity(0.3)),
    ),
    ),
    child: const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
    Icon(Icons.check_rounded, size: 18),
    SizedBox(width: 8),
    Text('موافقة'),
    ],
    ),
    ),
    ),
    const SizedBox(width: 8),
    Expanded(
    child: ElevatedButton(
    onPressed: () => _updateLeaveStatus(
    request['requestId']?.toString() ??
    request['id']?.toString() ??
    '',
    index,
    'rejected'),
    style: ElevatedButton.styleFrom(
    backgroundColor: Ar.red.withOpacity(0.1),
    foregroundColor: Ar.red,
    elevation: 0,
    shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(12),
    side: BorderSide(color: Ar.red.withOpacity(0.3)),
    ),
    ),
    child: const Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
    Icon(Icons.close_rounded, size: 18),
    SizedBox(width: 8),
    Text('رفض'),
    ],
    ),
    ),
    ),
    ],
    ),
    const SizedBox(height: 12),
    ],

    // EXPANDABLE CONTENT
    if (isExpanded) ...[
    Divider(
    color: dividerColor,
    height: 1,
    ),
    const SizedBox(height: 12),

    // Date Range - EXPANDED
    Row(
    children: [
    Icon(
    Icons.calendar_today_rounded,
    size: 18,
    color: subduedTextColor,
    ),
    const SizedBox(width: 8),
    Expanded(
    child: Text(
    '${_formatDate(request['fromDate']?.toString() ?? request['startDate']?.toString() ?? '')} - ${_formatDate(request['toDate']?.toString() ?? request['endDate']?.toString() ?? '')}',
    style: TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w600,
    color: textColor,
    ),
    ),
    ),
    ],
    ),

    const SizedBox(height: 8),

    // Submission Date - EXPANDED
    Row(
    children: [
    Icon(
    Icons.access_time_rounded,
    size: 18,
    color: subduedTextColor,
    ),
    const SizedBox(width: 8),
    Text(
    'تاريخ التقديم: ${_formatDate(request['submittedDate']?.toString() ?? request['createdAt']?.toString() ?? request['requestDate']?.toString() ?? '')}',
    style: TextStyle(
    fontSize: 12,
    color: subduedTextColor,
    ),
    ),
    ],
    ),

    const SizedBox(height: 8),

    // Employee ID - EXPANDED
    if (employeeId.isNotEmpty)
    Padding(
    padding: const EdgeInsets.only(right: 26),
    child: Text(
    'الرقم الوظيفي: $employeeId',
    style: TextStyle(
    fontSize: 12,
    color: subduedTextColor,
    ),
    ),
    ),

    const SizedBox(height: 12),

    // Reason - EXPANDED
    Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
    Text(
    'السبب:',
    style: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: subduedTextColor,
    ),
    ),
    const SizedBox(height: 4),
    Text(
    request['reason']?.toString() ?? 'لا يوجد سبب',
    style: TextStyle(
    fontSize: 14,
    color: textColor,
    ),
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    ),
    ],
    ),

    if ((request['notes']?.toString() ?? '').isNotEmpty) ...[
    const SizedBox(height: 8),
    Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
    Text(
    'ملاحظات الإدارة:',
    style: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: subduedTextColor,
    ),
    ),
    const SizedBox(height: 4),
    Text(
    request['notes']?.toString() ?? '',
    style: TextStyle(
    fontSize: 12,
    color: textColor,
    fontStyle: FontStyle.italic,
    ),
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    ),
    ],
    ),
    ],

    if (hasImage) ...[
    const SizedBox(height: 12),
    Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
    Text(
    'المرفق:',
    style: TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: subduedTextColor,
    ),
    ),
    const SizedBox(height: 8),
    GestureDetector(
    onTap: () {
    _showImageDialog(context, imageUrl!, isDark);
    },
    child: Container(
    width: double.infinity,
    height: 150,
    decoration: BoxDecoration(
    borderRadius: BorderRadius.circular(12),
    border: Border.all(
    color: isDark
    ? Colors.white.withOpacity(0.2)
        : Ar.grey.shade300,
    ),
    ),
    child: ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: Image.network(
    imageUrl!,
    fit: BoxFit.cover,
    loadingBuilder: (context, child, loadingProgress) {
    if (loadingProgress == null) return child;
    return Center(
    child: CircularProgressIndicator(
    value: loadingProgress.expectedTotalBytes != null
    ? loadingProgress.cumulativeBytesLoaded /
    loadingProgress.expectedTotalBytes!
        : null,
    ),
    );
    },
    errorBuilder: (context, error, stackTrace) {
    return Container(
    color: isDark
    ? Ar.grey.shade800
        : Ar.grey.shade200,
    child: Center(
    child: Column(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
    Icon(
    Icons.broken_image,
    size: 40,
    color: subduedTextColor,
    ),
    const SizedBox(height: 8),
    Text(
    'فشل تحميل الصورة',
    style: TextStyle(
    color: subduedTextColor,
    fontSize: 12,
    ),
    ),
    ],
    ),
    ),
    );
    },
    ),
    ),
    ),
    ),
    const SizedBox(height: 4),
    Text(
    'انقر على الصورة لعرضها بالحجم الكامل',
    style: TextStyle(
    fontSize: 10,
    color: subduedTextColor,
    fontStyle: FontStyle.italic,
    ),
    ),
    ],
    ),
    ],
    ],
    ],
    ),
    ),
    );
  }
}

// ================== Shared Widgets for Filter Sheet ==================
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

void _showImageDialog(BuildContext context, String imageUrl, bool isDark) {
  showDialog(
    context: context,
    builder: (context) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(20),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            decoration: Glass.sheet(isDark, r: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: Glass.tile(isDark, r: 12),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'الصورة المرفقة',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          width: 36,
                          height: 36,
                          decoration: Glass.tile(isDark, r: 12),
                          child: Icon(
                            Icons.close_rounded,
                            size: 20,
                            color:
                            isDark ? Colors.white70 : Ar.grey.shade700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Container(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.7,
                      maxHeight: MediaQuery.of(context).size.height * 0.5,
                    ),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.1),
                          blurRadius: 15,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(16),
                      child: Image.network(
                        imageUrl,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            width: 200,
                            height: 200,
                            decoration: Glass.panel(isDark, r: 16),
                            child: Center(
                              child: CircularProgressIndicator(
                                value: loadingProgress.expectedTotalBytes !=
                                    null
                                    ? loadingProgress.cumulativeBytesLoaded /
                                    loadingProgress.expectedTotalBytes!
                                    : null,
                                color: isDark ? Colors.white : Ar.info,
                              ),
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Container(
                            width: 200,
                            height: 200,
                            decoration: Glass.panel(isDark, r: 16),
                            child: Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.broken_image_rounded,
                                    size: 48,
                                    color: isDark
                                        ? Colors.white60
                                        : Ar.grey.shade600,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'فشل تحميل الصورة',
                                    style: TextStyle(
                                      fontSize: 14,
                                      color: isDark
                                          ? Colors.white70
                                          : Ar.grey.shade700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),

                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.black.withOpacity(0.3)
                        : Colors.white.withOpacity(0.5),
                    border: Border(
                      top: BorderSide(
                        color: isDark
                            ? Colors.white.withOpacity(0.1)
                            : Ar.grey.withOpacity(0.2),
                      ),
                    ),
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(24),
                      bottomRight: Radius.circular(24),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: () async {
                            await Clipboard.setData(
                                ClipboardData(text: imageUrl));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('تم نسخ رابط الصورة'),
                                backgroundColor: Ar.green,
                              ),
                            );
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            decoration: Glass.panel(isDark, r: 14),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.link_rounded,
                                  size: 18,
                                  color: isDark
                                      ? Ar.info.shade300
                                      : Ar.info,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'نسخ الرابط',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: isDark
                                        ? Ar.info.shade300
                                        : Ar.info,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        onTap: () => Navigator.pop(context),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                          decoration: Glass.panel(isDark, r: 14),
                          child: Text(
                            'إغلاق',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white70
                                  : Ar.grey.shade700,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}