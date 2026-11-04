import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/stat_cards.dart';
import '../../services/dashboard_api.dart';
import '../../services/dashboard_state.dart';
import '../../services/camera_service.dart';
import '../../services/notification_service.dart'; // ✅ إضافة الاستيراد
import '../attendance/attendance_report_page.dart';
import '../employees/employees_page.dart';
import '../selfie_preview_page.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../profile/profile_page.dart';
import '../settings/settings_page.dart';
import '../id_card_page.dart';
import '../leave_request_page.dart';
import 'attendance_today_page.dart';
import 'break_alert_dialog.dart';
import 'break_page.dart';
import 'fingerprint_config.dart';
import 'top_tabs.dart';
import 'dash_mode.dart';
import '../notifications/notifications_page.dart';
import 'attendance_today_page.dart';
import 'break_page.dart';
import '../notifications/notification_settings.dart'; // ✅ إضافة صفحة إعدادات الإشعارات

class DashboardPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  final String photo;

  const DashboardPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
    this.photo = "",
  });

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  late CameraService _cameraService;
  late AudioPlayer _audioPlayer;
  bool _cameraInUse = false;
  DashMode mode = DashMode.check;
  DashboardState state = DashboardState.empty();
  Map<String, dynamic> sheetData = {};
  bool loading = true;
  bool _isRefreshing = false;
  int bottomIndex = 0;
  Timer? _updateTimer;

  // ✅ متغيرات جديدة للكروت
  List<Map<String, dynamic>> _leaveRequests = [];
  List<Map<String, dynamic>> _loanRequests = [];
  List<Map<String, dynamic>> _attendanceByProject = [];
  Map<String, dynamic> _todayStats = {
    'totalEmployees': 0,
    'presentCount': 0,
    'absentCount': 0,
  };

  // 🔥 متغيرات لحل مشكلة المؤقت
  DateTime? _localBreakStart;
  DateTime? _localWorkStart;

  // 🔥 متغيرات للمعالجة
  final Map<String, bool> _processingRequests = {};

  // أنيميشنات التحميل
  late AnimationController _loadingAnimationController;
  late Animation<double> _loadingFadeAnimation;
  late Animation<double> _loadingScaleAnimation;

  bool get onActiveBreak => state.onBreak && state.breakEndTime == "--:--";

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cameraService = CameraService();
    _audioPlayer = AudioPlayer();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final appController = Provider.of<AppController>(context, listen: false);
      if (appController.userPhoto != null) {
        setState(() {});
      }

      // ✅ إرسال التوكن عند فتح لوحة التحكم إذا لم يكن مرسلاً
      try {
        final notificationService = NotificationService();
        await notificationService.sendTokenIfNeeded(widget.uid);
      } catch (e) {
        print('⚠️ فشل إرسال التوكن في لوحة التحكم: $e');
      }
    });

    _loadingAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    _loadingFadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _loadingAnimationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeInOut),
      ),
    );

    _loadingScaleAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _loadingAnimationController,
        curve: const Interval(0.3, 0.9, curve: Curves.elasticOut),
      ),
    );

    _loadInitialData();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _forceCloseCamera();
      _audioPlayer.stop();
      _cacheTimerStates();
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _forceCloseCamera();
    _audioPlayer.dispose();
    _loadingAnimationController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // 🔥 دالة لحفظ حالة المؤقتات
  Future<void> _cacheTimerStates() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      if (checkedIn && _localWorkStart != null) {
        await prefs.setInt(
          '${widget.uid}_work_start',
          _localWorkStart!.millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove('${widget.uid}_work_start');
      }

      if (onActiveBreak && _localBreakStart != null) {
        await prefs.setInt(
          '${widget.uid}_break_start',
          _localBreakStart!.millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove('${widget.uid}_break_start');
      }
    } catch (e) {
      print('❌ خطأ في حفظ حالة المؤقتات: $e');
    }
  }

  // 🔥 دالة لاستعادة حالة المؤقتات
  Future<void> _restoreTimerStates() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      final workStartMillis = prefs.getInt('${widget.uid}_work_start');
      if (checkedIn && workStartMillis != null) {
        _localWorkStart = DateTime.fromMillisecondsSinceEpoch(workStartMillis);
      }

      final breakStartMillis = prefs.getInt('${widget.uid}_break_start');
      if (onActiveBreak && breakStartMillis != null) {
        _localBreakStart = DateTime.fromMillisecondsSinceEpoch(breakStartMillis);
      }
    } catch (e) {
      print('❌ خطأ في استعادة حالة المؤقتات: $e');
    }
  }

  // 🔥 دالة لمسح وقت الاستراحة المحفوظ
  Future<void> _clearBreakStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${widget.uid}_break_start');
    } catch (e) {
      print('❌ خطأ في مسح وقت الاستراحة: $e');
    }
  }

  // 🔥 دالة لمسح وقت العمل المحفوظ
  Future<void> _clearWorkStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${widget.uid}_work_start');
    } catch (e) {
      print('❌ خطأ في مسح وقت العمل: $e');
    }
  }

  void onBottomTap(int index) {
    if (index == bottomIndex) return;

    switch (index) {
      case 1:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AttendanceReportPage(uid: '', name: '', role: '',
            ),
          ),
        );
        break;
      case 3:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SettingsPage(
              uid: widget.uid,
              name: widget.name,
              role: widget.role,
            ),
          ),
        );
        break;
      case 2:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EmployeesPage(currentUserId: '', currentUserName: '', currentUserRole: '',
            ),
          ),
        );
        break;
      case 4:
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => ProfilePage(
              uid: widget.uid,
              name: widget.name,
              role: widget.role,
              photo: _photoUrl,
            ),
          ),
        );
        break;
    }
  }

  Future<void> _loadInitialData() async {
    await loadToday();
    await _loadAdditionalData();
    _restoreTimerStates();
  }

  Future<void> loadToday() async {
    try {
      _isRefreshing = true;
      if (mounted) setState(() {});

      final res = await DashboardApi.getDashboardData(widget.uid);
      if (!mounted) {
        _isRefreshing = false;
        return;
      }

      if (res["success"] == true) {
        setState(() {
          state = DashboardState.fromApi(res);
          sheetData = res;
          loading = false;
          _isRefreshing = false;
        });

        final photoUrl = (res["photo"] ?? "").toString().trim();
        if (photoUrl.isNotEmpty) {
          final appController = Provider.of<AppController>(context, listen: false);
          appController.saveUserPhoto(photoUrl);
        }

        if (dayFinished) {
          await _clearWorkStart();
          _localWorkStart = null;
        }

        if (breakFinished) {
          await _clearBreakStart();
          _localBreakStart = null;
        }

        _initializeLocalTimers();
        _loadingAnimationController.stop();
      } else {
        setState(() {
          loading = false;
          _isRefreshing = false;
        });
        _loadingAnimationController.stop();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          _isRefreshing = false;
        });
        _loadingAnimationController.stop();
      }
    }
  }

  // ✅ دالة جديدة لتحميل البيانات الإضافية
  Future<void> _loadAdditionalData() async {
    try {
      // تحميل طلبات الإجازة
      final leaveRes = await DashboardApi.getLeaveRequests(widget.uid);
      if (leaveRes["success"] == true) {
        setState(() {
          _leaveRequests = List<Map<String, dynamic>>.from(leaveRes["requests"] ?? []);
        });
      }

      // تحميل طلبات السلف
      final loanRes = await DashboardApi.getLoanRequests(widget.uid);
      if (loanRes["success"] == true) {
        setState(() {
          _loanRequests = List<Map<String, dynamic>>.from(loanRes["requests"] ?? []);
        });
      }

      // تحميل إحصائيات اليوم
      final statsRes = await DashboardApi.getTodayStats(widget.uid);
      if (statsRes["success"] == true) {
        setState(() {
          _todayStats = Map<String, dynamic>.from(statsRes["stats"] ?? {});
        });
      }

      // تحميل الحضور حسب المشروع
      final projectRes = await DashboardApi.getAttendanceByProject(widget.uid);
      if (projectRes["success"] == true) {
        setState(() {
          _attendanceByProject = List<Map<String, dynamic>>.from(projectRes["projects"] ?? []);
        });
      }
    } catch (e) {
      print('❌ خطأ في تحميل البيانات الإضافية: $e');
    }
  }

  void _initializeLocalTimers() {
    // مؤثر العمل
    if (checkedIn && _localWorkStart == null) {
      _localWorkStart = DateTime.now();
    } else if (!checkedIn) {
      _localWorkStart = null;
    }

    // مؤثر الاستراحة
    if (onActiveBreak && _localBreakStart == null) {
      _localBreakStart = DateTime.now();
    } else if (!state.onBreak) {
      _localBreakStart = null;
    }
  }

  bool get checkedIn =>
      state.checkInTime != "--:--" && state.checkOutTime == "--:--";

  bool get breakFinished =>
      state.breakStartTime != "--:--" && state.breakEndTime != "--:--";

  bool get dayFinished =>
      state.checkInTime != "--:--" && state.checkOutTime != "--:--";

  String get _photoUrl {
    final p1 = widget.photo.trim();
    if (p1.isNotEmpty) return p1;

    final p2 = (sheetData["photo"] ?? "").toString().trim();
    if (p2.isNotEmpty) return p2;

    return "";
  }

  String _getTodayLabel(BuildContext context) {
    final now = DateTime.now();
    final dayName = AppLocalizations.of(context, 'day_${now.weekday}');
    final dd = now.day.toString().padLeft(2, "0");
    final mm = now.month.toString().padLeft(2, "0");
    final yyyy = now.year.toString();
    return "${AppLocalizations.of(context, 'today')} $dayName $dd / $mm / $yyyy";
  }

  FingerUiConfig _getFingerConfig(BuildContext context) {
    final appController = Provider.of<AppController>(context, listen: false);
    final isDark = appController.isDark;

    Color getPrimaryColor() => isDark ? AppColors.primaryLight : AppColors.primary;
    Color getSecondaryColor() => isDark ? AppColors.secondaryLight : AppColors.secondary;
    Color getAccentColor() => isDark ? AppColors.accentLight : AppColors.accent;
    Color getErrorColor() => AppColors.error;

    switch (mode) {
      case DashMode.check:
      // ✅ تغيير الزر ليعرض الموظفين الحاضرين
        return FingerUiConfig(
          title: AppLocalizations.of(context, 'show_today_attendance'),
          subtitle: "عرض الموظفين الحاضرين اليوم",
          color: getPrimaryColor(),
          iconBg: getPrimaryColor(),
        );

      case DashMode.breakTime:
      // ✅ تغيير الزر ليعرض الموظفين في الاستراحة
        return FingerUiConfig(
          title: AppLocalizations.of(context, 'show_break_employees'),
          subtitle: "عرض الموظفين في الاستراحة",
          color: getAccentColor(),
          iconBg: getAccentColor(),
        );

      case DashMode.leave:
        return FingerUiConfig(
          title: AppLocalizations.of(context, 'leave_requests'),
          subtitle: "طلبات الإجازة",
          color: getPrimaryColor(),
          iconBg: getPrimaryColor(),
        );
    }
  }

  StatRightCardModel _getRightCard(BuildContext context) {
    switch (mode) {
      case DashMode.breakTime:
        return StatRightCardModel.breakTime(
          start: state.breakStartTime,
          end: state.breakEndTime,
          total: state.breakTime,
        );
      case DashMode.leave:
        return StatRightCardModel.leave(
          leaveDays: "0",
          leaveAttendance: "0",
          sickLeave: "0",
        );

      case DashMode.check:
      default:
        return StatRightCardModel.check(
          checkTime: state.checkInTime,
          checkOutTime: state.checkOutTime,
          workTime: checkedIn ? _calcWorkTime() : ((sheetData["workTime"] ?? "--:--") as String),
        );
    }
  }

  String _calcWorkTime() {
    if (!checkedIn || _localWorkStart == null) {
      return "--:--:--";
    }

    final now = DateTime.now();
    final difference = now.difference(_localWorkStart!);
    final totalSeconds = difference.inSeconds;

    if (totalSeconds <= 0) return "00:00:01";

    final h = difference.inHours.toString().padLeft(2, "0");
    final m = (difference.inMinutes % 60).toString().padLeft(2, "0");
    final s = (difference.inSeconds % 60).toString().padLeft(2, "0");
    return "$h:$m:$s";
  }

  void setTab(DashMode m) => setState(() => mode = m);

  Future<void> onFingerSuccess() async {
    final currentContext = context;
    final config = _getFingerConfig(currentContext);

    if (_cameraInUse) return;

    if (mode == DashMode.leave) {
      await Navigator.push(
        currentContext,
        MaterialPageRoute(
          builder: (_) => LeaveRequestPage(
            uid: widget.uid,
            name: widget.name,
            role: widget.role,
          ),
        ),
      );
      return;
    }

    if (mode == DashMode.check) {
      // ✅ الانتقال لصفحة عرض الموظفين الحاضرين
      await Navigator.push(
        currentContext,
        MaterialPageRoute(
          builder: (_) => AttendanceTodayPage(
            uid: widget.uid,
            name: widget.name,
            role: widget.role,
          ),
        ),
      );
      return;
    }

    if (mode == DashMode.breakTime) {
      // ✅ الانتقال لصفحة عرض الموظفين في الاستراحة
      await Navigator.push(
        currentContext,
        MaterialPageRoute(
          builder: (_) => BreakPage(
            uid: widget.uid,
            name: widget.name,
            role: widget.role,
          ),
        ),
      );
      return;
    }
  }

  void _forceCloseCamera() {
    if (_cameraService.isInitialized) {
      _cameraService.dispose();
    }
  }

  Future<void> _handleRefresh() async {
    await Future.wait([loadToday(), _loadAdditionalData()]);
  }

  // ✅ ويدجت لكارت طلبات الإجازة - محدث
  Widget _buildLeaveRequestsCard(BuildContext context) {
    if (_leaveRequests.isEmpty) return const SizedBox.shrink();

    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.2) : Colors.blue.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '📄 ${AppLocalizations.of(context, 'new_leave_requests')} (${_leaveRequests.length})',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.blue[800],
                ),
              ),
              if (_leaveRequests.length > 2)
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => LeaveRequestPage(
                          uid: widget.uid,
                          name: widget.name,
                          role: widget.role,
                        ),
                      ),
                    );
                  },
                  child: Text(
                    AppLocalizations.of(context, 'view_all'),
                    style: TextStyle(
                      color: isDark ? Colors.blue[300] : Colors.blue,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ..._leaveRequests.take(2).map((request) {
            // ✅ عرض بيانات الإجازة
            final startDate = request['startDate'] ?? '';
            final endDate = request['endDate'] ?? '';
            final daysCount = request['daysCount'] ?? '0';
            final leaveType = request['leaveType'] ?? '';
            final reason = request['reason'] ?? '';

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '👤 ${request['employeeName']}',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                      Text(
                        '📅 ${request['requestDate']}',
                        style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // ✅ عرض تفاصيل الإجازة
                  Text(
                    '🗓️ الفترة: $startDate إلى $endDate',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white70 : Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '⏱️ عدد الأيام: $daysCount أيام',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white70 : Colors.grey[700],
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '📝 نوع الإجازة: $leaveType',
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white70 : Colors.grey[700],
                    ),
                  ),
                  if (reason.isNotEmpty && reason != "null") ...[
                    const SizedBox(height: 2),
                    Text(
                      '💬 السبب: $reason',
                      style: TextStyle(
                        fontSize: 12,
                        color: isDark ? Colors.white70 : Colors.grey[700],
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _processingRequests['leave_${request['id']}'] == true
                              ? null
                              : () => _approveLeaveRequest(request['id']),
                          icon: _processingRequests['leave_${request['id']}'] == true
                              ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                              : const Icon(Icons.check, size: 18),
                          label: _processingRequests['leave_${request['id']}'] == true
                              ? Text(AppLocalizations.of(context, 'processing'))
                              : Text(AppLocalizations.of(context, 'approve')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _processingRequests['leave_${request['id']}'] == true
                              ? null
                              : () => _rejectLeaveRequest(request['id']),
                          icon: _processingRequests['leave_${request['id']}'] == true
                              ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                              : const Icon(Icons.close, size: 18),
                          label: _processingRequests['leave_${request['id']}'] == true
                              ? Text(AppLocalizations.of(context, 'processing'))
                              : Text(AppLocalizations.of(context, 'reject')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (_leaveRequests.indexOf(request) < _leaveRequests.take(2).length - 1)
                    const Divider(height: 20),
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  // ✅ ويدجت لكارت طلبات السلف - محدث
  Widget _buildLoanRequestsCard(BuildContext context) {
    if (_loanRequests.isEmpty) return const SizedBox.shrink();

    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.2) : Colors.green.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '💰 ${AppLocalizations.of(context, 'new_financial_requests')} (${_loanRequests.length})',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.green[800],
                ),
              ),
              if (_loanRequests.length > 2)
                TextButton(
                  onPressed: () {
                    // يمكن إضافة صفحة لعرض جميع الطلبات المالية
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('عرض جميع الطلبات المالية'),
                        backgroundColor: Colors.blue,
                      ),
                    );
                  },
                  child: Text(
                    AppLocalizations.of(context, 'view_all'),
                    style: TextStyle(
                      color: isDark ? Colors.green[300] : Colors.green,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ..._loanRequests.take(2).map((request) {
            // ✅ عرض بيانات الطلب المالي
            final amount = request['amount'] ?? '0';
            final requestType = request['requestType'] ?? '';
            final month = request['month'] ?? '';
            final notes = request['notes'] ?? '';
            final requestDate = request['requestDate'] ?? '';

            // تحديد لون حسب نوع الطلب
            Color getRequestTypeColor(String type) {
              switch (type) {
                case 'سلفه':
                  return Colors.blue;
                case 'مصاريف عمل':
                  return Colors.orange;
                case 'قبض':
                  return Colors.green;
                case 'خصم':
                  return Colors.red;
                case 'بدلات':
                  return Colors.purple;
                case 'علاوة':
                  return Colors.amber;
                case 'دفع':
                  return Colors.cyan;
                case 'استلام':
                  return Colors.teal;
                case 'زياده الراتب':
                  return Colors.deepOrange;
                default:
                  return Colors.grey;
              }
            }

            final typeColor = getRequestTypeColor(requestType);

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // معلومات الموظف
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(
                          '👤 ${request['employeeName']}',
                          style: TextStyle(
                            fontWeight: FontWeight.w500,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                        ),
                      ),
                      Text(
                        '📅 $requestDate',
                        style: TextStyle(
                          color: isDark ? Colors.white70 : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),

                  // نوع الطلب
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: typeColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: typeColor.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      '📝 $requestType',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: typeColor,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),

                  // المبلغ
                  Text(
                    '💵 المبلغ: $amount جنيه',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: isDark ? Colors.white : Colors.green[700],
                    ),
                  ),

                  // الشهر
                  if (month.isNotEmpty && month != "null")
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '🗓️ الشهر: $month',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.grey[700],
                        ),
                      ),
                    ),

                  // الملاحظات
                  if (notes.isNotEmpty && notes != "null")
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '📌 الملاحظات: $notes',
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white70 : Colors.grey[700],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),

                  const SizedBox(height: 8),

                  // أزرار الموافقة والرفض
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _processingRequests['loan_${request['id']}'] == true
                              ? null
                              : () => _approveLoanRequest(request['id']),
                          icon: _processingRequests['loan_${request['id']}'] == true
                              ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                              : const Icon(Icons.check, size: 18),
                          label: _processingRequests['loan_${request['id']}'] == true
                              ? Text(AppLocalizations.of(context, 'processing'))
                              : Text(AppLocalizations.of(context, 'approve')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.green,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _processingRequests['loan_${request['id']}'] == true
                              ? null
                              : () => _rejectLoanRequest(request['id']),
                          icon: _processingRequests['loan_${request['id']}'] == true
                              ? SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                              : const Icon(Icons.close, size: 18),
                          label: _processingRequests['loan_${request['id']}'] == true
                              ? Text(AppLocalizations.of(context, 'processing'))
                              : Text(AppLocalizations.of(context, 'reject')),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.red,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(vertical: 8),
                          ),
                        ),
                      ),
                    ],
                  ),

                  if (_loanRequests.indexOf(request) < _loanRequests.take(2).length - 1)
                    const Divider(height: 20),
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  // ✅ ويدجت لكارت إحصائيات اليوم
  Widget _buildTodayStatsCard(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.2) : Colors.purple.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '📊 ${AppLocalizations.of(context, 'today_stats')}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.purple[800],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: _buildStatItem(
                  context: context,
                  icon: '👥',
                  title: AppLocalizations.of(context, 'total_employees'),
                  value: _todayStats['totalEmployees'].toString(),
                  color: Colors.blue,
                ),
              ),
              Expanded(
                child: _buildStatItem(
                  context: context,
                  icon: '✅',
                  title: AppLocalizations.of(context, 'present'),
                  value: _todayStats['presentCount'].toString(),
                  color: Colors.green,
                ),
              ),
              Expanded(
                child: _buildStatItem(
                  context: context,
                  icon: '❌',
                  title: AppLocalizations.of(context, 'absent'),
                  value: _todayStats['absentCount'].toString(),
                  color: Colors.red,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ✅ ويدجت لكارت الحضور حسب المشروع
  Widget _buildProjectAttendanceCard(BuildContext context) {
    if (_attendanceByProject.isEmpty) return const SizedBox.shrink();

    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isDark ? Colors.white.withOpacity(0.2) : Colors.orange.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '🏗️ ${AppLocalizations.of(context, 'attendance_by_project')}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.orange[800],
            ),
          ),
          const SizedBox(height: 12),
          ..._attendanceByProject.map((project) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      project['projectName'],
                      style: TextStyle(
                        color: isDark ? Colors.white : Colors.black,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                    decoration: BoxDecoration(
                      color: isDark ? Colors.white.withOpacity(0.2) : Colors.orange.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${project['attendanceCount']} ${AppLocalizations.of(context, 'employees')}',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: isDark ? Colors.white : Colors.orange[800],
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required BuildContext context,
    required String icon,
    required String title,
    required String value,
    required Color color,
  }) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Column(
      children: [
        Text(
          icon,
          style: const TextStyle(fontSize: 24),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: isDark ? Colors.white : color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            color: isDark ? Colors.white70 : Colors.grey[700],
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  // ✅ دوال للموافقة والرفض - محدثة
  // ✅ دوال للموافقة والرفض - محدثة
  Future<void> _approveLeaveRequest(String requestId) async {
    try {
      print('✅ محاولة الموافقة على طلب الإجازة: $requestId');

      // تعيين حالة المعالجة
      setState(() {
        _processingRequests['leave_$requestId'] = true;
      });

      final result = await DashboardApi.approveLeaveRequest(requestId, widget.uid);
      print('📊 نتيجة الموافقة على الإجازة: $result');

      // إزالة حالة المعالجة
      setState(() {
        _processingRequests.remove('leave_$requestId');
      });

      if (result["success"] == true) {
        // إزالة الطلب من القائمة
        setState(() {
          _leaveRequests.removeWhere((request) => request['id'] == requestId);
        });

        // عرض رسالة نجاح
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "تمت الموافقة على طلب الإجازة"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }

        // إعادة تحميل البيانات بعد 2 ثانية
        await Future.delayed(Duration(seconds: 2));
        await _loadAdditionalData();

      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "فشل في الموافقة على الطلب"),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ خطأ في الموافقة على طلب الإجازة: $e');
      setState(() {
        _processingRequests.remove('leave_$requestId');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في الاتصال: $e"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _rejectLeaveRequest(String requestId) async {
    try {
      print('❌ محاولة رفض طلب الإجازة: $requestId');

      // تعيين حالة المعالجة
      setState(() {
        _processingRequests['leave_$requestId'] = true;
      });

      final result = await DashboardApi.rejectLeaveRequest(requestId, widget.uid);
      print('📊 نتيجة رفض الإجازة: $result');

      // إزالة حالة المعالجة
      setState(() {
        _processingRequests.remove('leave_$requestId');
      });

      if (result["success"] == true) {
        // إزالة الطلب من القائمة
        setState(() {
          _leaveRequests.removeWhere((request) => request['id'] == requestId);
        });

        // عرض رسالة نجاح
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "تم رفض طلب الإجازة"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }

        // إعادة تحميل البيانات بعد 2 ثانية
        await Future.delayed(Duration(seconds: 2));
        await _loadAdditionalData();

      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "فشل في رفض الطلب"),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ خطأ في رفض طلب الإجازة: $e');
      setState(() {
        _processingRequests.remove('leave_$requestId');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في الاتصال: $e"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _approveLoanRequest(String requestId) async {
    try {
      print('✅ محاولة الموافقة على طلب السلف: $requestId');

      // تعيين حالة المعالجة
      setState(() {
        _processingRequests['loan_$requestId'] = true;
      });

      final result = await DashboardApi.approveLoanRequest(requestId, widget.uid);
      print('📊 نتيجة الموافقة على السلف: $result');

      // إزالة حالة المعالجة
      setState(() {
        _processingRequests.remove('loan_$requestId');
      });

      if (result["success"] == true) {
        // إزالة الطلب من القائمة
        setState(() {
          _loanRequests.removeWhere((request) => request['id'] == requestId);
        });

        // عرض رسالة نجاح
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "تمت الموافقة على طلب السلف"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }

        // إعادة تحميل البيانات بعد 2 ثانية
        await Future.delayed(Duration(seconds: 2));
        await _loadAdditionalData();

      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "فشل في الموافقة على الطلب"),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ خطأ في الموافقة على طلب السلف: $e');
      setState(() {
        _processingRequests.remove('loan_$requestId');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في الاتصال: $e"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  Future<void> _rejectLoanRequest(String requestId) async {
    try {
      print('❌ محاولة رفض طلب السلف: $requestId');

      // تعيين حالة المعالجة
      setState(() {
        _processingRequests['loan_$requestId'] = true;
      });

      final result = await DashboardApi.rejectLoanRequest(requestId, widget.uid);
      print('📊 نتيجة رفض السلف: $result');

      // إزالة حالة المعالجة
      setState(() {
        _processingRequests.remove('loan_$requestId');
      });

      if (result["success"] == true) {
        // إزالة الطلب من القائمة
        setState(() {
          _loanRequests.removeWhere((request) => request['id'] == requestId);
        });

        // عرض رسالة نجاح
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "تم رفض طلب السلف"),
              backgroundColor: Colors.green,
              duration: Duration(seconds: 3),
            ),
          );
        }

        // إعادة تحميل البيانات بعد 2 ثانية
        await Future.delayed(Duration(seconds: 2));
        await _loadAdditionalData();

      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(result["message"] ?? "فشل في رفض الطلب"),
              backgroundColor: Colors.red,
              duration: Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (e) {
      print('❌ خطأ في رفض طلب السلف: $e');
      setState(() {
        _processingRequests.remove('loan_$requestId');
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في الاتصال: $e"),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }
  Widget _buildDashboardHome() {
    return SafeArea(
      child: RefreshIndicator(
        onRefresh: _handleRefresh,
        color: AppColors.primary,
        backgroundColor: Colors.transparent,
        child: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: [
                      _buildHeader(),

                      const SizedBox(height: 18),
                      TopTabs(mode: mode, onTap: setTab),

                      const SizedBox(height: 18),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                AnimatedFingerprintAction(
                                  key: ValueKey(
                                    "${state.checkInTime}-${state.checkOutTime}-${state.onBreak}",
                                  ),
                                  config: _getFingerConfig(context),
                                  onSuccess: onFingerSuccess,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: StatRightCard(model: _getRightCard(context)),
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // ✅ عرض الكروت الجديدة
                      _buildLeaveRequestsCard(context),
                      _buildLoanRequestsCard(context),
                      _buildTodayStatsCard(context),
                      _buildProjectAttendanceCard(context),

                      const SizedBox(height: 90),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;

    return Consumer<AppController>(
      builder: (context, appController, child) {
        final controllerPhoto = appController.userPhoto;
        final apiPhoto = _photoUrl;
        final photo = controllerPhoto ?? apiPhoto;

        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            GestureDetector(
              onTap: () async {
                final result = await Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => NotificationsPage(
                      uid: widget.uid,
                      name: widget.name,
                      role: widget.role,
                    ),
                  ),
                );
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark
                      ? Colors.white.withOpacity(0.15)
                      : AppColors.primary.withOpacity(0.1),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.2)
                        : AppColors.primary.withOpacity(0.2),
                    width: 1,
                  ),
                ),
                child: const Icon(
                  Icons.notifications,
                  size: 24,
                  color: Colors.blue,
                ),
              ),
            ),

            Column(
              children: [
                Text(
                  _getTodayLabel(context),
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white70 : Colors.grey.shade700,
                  ),
                ),
                Text(
                  widget.name,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                Text(
                  widget.role,
                  style: TextStyle(
                    fontSize: 12,
                    color: isDark ? Colors.white60 : Colors.grey.shade600,
                  ),
                ),
              ],
            ),

            GestureDetector(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => ProfilePage(
                      uid: widget.uid,
                      name: widget.name,
                      role: widget.role,
                      photo: photo,
                    ),
                  ),
                );
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark
                      ? Colors.white.withOpacity(0.15)
                      : Colors.white.withOpacity(0.25),
                  border: Border.all(
                    color: isDark
                        ? Colors.white.withOpacity(0.2)
                        : AppColors.primary.withOpacity(0.2),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 6,
                      spreadRadius: 1,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: photo.isNotEmpty
                      ? Image.network(
                    photo,
                    fit: BoxFit.cover,
                    loadingBuilder: (context, child, loadingProgress) {
                      if (loadingProgress == null) return child;
                      return Center(
                        child: CircularProgressIndicator(
                          value: loadingProgress.expectedTotalBytes != null
                              ? loadingProgress.cumulativeBytesLoaded /
                              loadingProgress.expectedTotalBytes!
                              : null,
                          strokeWidth: 2,
                        ),
                      );
                    },
                    errorBuilder: (context, error, stackTrace) {
                      return _buildDefaultAvatar(isDark);
                    },
                  )
                      : _buildDefaultAvatar(isDark),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildDefaultAvatar(bool isDark) {
    return Center(
      child: Icon(
        Icons.person,
        size: 24,
        color: isDark ? Colors.white70 : Colors.grey.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);

    if (loading) {
      return Consumer<AppController>(
        builder: (context, appController, _) {
          final isDark = appController.isDark;

          Widget _fallbackBackground(bool isDark) {
            return Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: isDark
                      ? [Colors.black87, Colors.grey[900]!]
                      : [Colors.blue[50]!, Colors.white],
                ),
              ),
            );
          }

          Widget _buildBackground(bool isDark) {
            try {
              final bgImage = isDark
                  ? 'assets/bg/dark_bg.png'
                  : 'assets/bg/light_bg.png';

              return Stack(
                children: [
                  Positioned.fill(
                    child: Image.asset(
                      bgImage,
                      fit: BoxFit.cover,
                      filterQuality: FilterQuality.low,
                      gaplessPlayback: true,
                      errorBuilder: (context, error, stackTrace) {
                        return _fallbackBackground(isDark);
                      },
                    ),
                  ),
                  IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            (isDark ? Colors.black : Colors.white)
                                .withOpacity(isDark ? 0.35 : 0.08),
                            Colors.transparent,
                            (isDark ? Colors.black : Colors.white)
                                .withOpacity(isDark ? 0.55 : 0.10),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              );
            } catch (e) {
              return _fallbackBackground(isDark);
            }
          }

          return Directionality(
            textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: Stack(
                children: [
                  Positioned.fill(
                    child: _buildBackground(isDark),
                  ),

                  Center(
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedBuilder(
                          animation: _loadingAnimationController,
                          builder: (_, child) {
                            return Transform.rotate(
                              angle: _loadingAnimationController.value * 2 * math.pi,
                              child: child,
                            );
                          },
                          child: CustomPaint(
                            size: const Size(200, 200),
                            painter: _DashboardCirclePainter(isDark: isDark),
                          ),
                        ),

                        AnimatedBuilder(
                          animation: _loadingAnimationController,
                          builder: (context, child) {
                            return Opacity(
                              opacity: _loadingFadeAnimation.value,
                              child: Transform.scale(
                                scale: _loadingScaleAnimation.value,
                                child: child,
                              ),
                            );
                          },
                          child: Image.asset(
                            'assets/images/logo.png',
                            width: 200,
                            height: 200,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    }

    return Consumer<AppController>(
      builder: (context, appController, _) {
        return AppBackground(
          child: Directionality(
            textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: _buildDashboardHome(),
              bottomNavigationBar: GlassBottomNav(
                currentIndex: bottomIndex,
                onTap: onBottomTap,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DashboardCirclePainter extends CustomPainter {
  final bool isDark;

  _DashboardCirclePainter({this.isDark = false});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    final orangePaint = Paint()
      ..shader = LinearGradient(
        colors: isDark
            ? [Colors.orangeAccent, Colors.deepOrange]
            : [Colors.orange, Colors.deepOrange],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      0,
      math.pi,
      false,
      orangePaint,
    );

    final bluePaint = Paint()
      ..shader = LinearGradient(
        colors: isDark
            ? [Colors.blue.shade200, Colors.blue.shade400]
            : [Colors.blue.shade300, Colors.blue.shade700],
      ).createShader(Rect.fromCircle(center: center, radius: radius))
      ..strokeWidth = 10
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      math.pi,
      math.pi,
      false,
      bluePaint,
    );

    final glowPaint = Paint()
      ..color = (isDark ? Colors.blue.shade200 : Colors.blue).withOpacity(0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15.0);

    canvas.drawCircle(center, radius + 5, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}