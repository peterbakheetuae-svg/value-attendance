import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../services/notification_service.dart';
import '../../theme/app_colors.dart';
import '../../widgets/stat_cards.dart';
import '../../services/dashboard_employees_api.dart';
import '../../services/dashboard_state.dart';
import '../../services/camera_service.dart';
import '../../services/pending_capture.dart';
import '../selfie_preview_page.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../profile/profile_page.dart';
import '../settings/settings_page.dart';
import '../id_card_page.dart';
import '../leave_request_page.dart';
import 'break_alert_dialog_team.dart';
import 'fingerprint_config_team.dart';
import 'month_stats_team.dart';
import 'today_stats_team.dart';
import 'top_tabs_team.dart';
import 'dash_mode_team.dart';
import '../notifications/notifications_page.dart';
import '../../services/api_service.dart';
import '../../widgets/performance_avatar.dart';
import '../../services/jph_bridge.dart';
import '../../widgets/outing_dialogs.dart';
import '../../widgets/app_nav.dart';
import '../../../core/shift_tracker.dart';

class DashboardPageTeam extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  final String photo;

  const DashboardPageTeam({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
    this.photo = "",
  });

  @override
  State<DashboardPageTeam> createState() => _DashboardPageTeamState();
}

class _DashboardPageTeamState extends State<DashboardPageTeam>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver, SingleTickerProviderStateMixin {
  @override
  bool get wantKeepAlive => true;

  late CameraService _cameraService;
  late AudioPlayer _audioPlayer;
  bool _cameraInUse = false;

  /// Retains the approved capture so a retry after a failed upload or check-in
  /// resends the same bytes with the same `uploadId` instead of forcing a new
  /// photo. Held in State, so a rebuild does not lose it.
  final PendingCaptureStore _pendingCaptures = PendingCaptureStore();
  DashMode mode = DashMode.check;
  DashboardState state = DashboardState.empty();
  Map<String, dynamic> sheetData = {};
  Map<String, dynamic> monthData = {};
  bool loading = true;
  bool _isRefreshing = false;
  final ValueNotifier<String> liveWorkTimeN = ValueNotifier("--:--:--");
  final ValueNotifier<String> liveBreakTimeN = ValueNotifier("--:--:--");
  int bottomIndex = 0;
  Timer? _updateTimer;
  Timer? _breakAlertTimer;
  bool _showBreakAlert = false;
  bool _hasPlayedSound = false;
  final GlobalKey<RefreshIndicatorState> _refreshIndicatorKey = GlobalKey<RefreshIndicatorState>();

  late AnimationController _loadingAnimationController;
  late Animation<double> _loadingFadeAnimation;
  late Animation<double> _loadingScaleAnimation;

  DateTime? _localBreakStart;
  DateTime? _localWorkStart;

  // hourly permission / external visit (replaces the break)
  Map<String, dynamic>? _outingPending;
  Map<String, dynamic>? _outingActive;
  String? _overdueRungFor;
  bool _outingDialogOpen = false;

  DateTime? get _outingReturn => DateTime.tryParse('${_outingActive?['expected_return_at']}')?.toLocal();
  bool get _outingOverdue => _outingActive != null && (_outingReturn?.isBefore(DateTime.now()) ?? false);

  bool get onActiveBreak => state.onBreak && state.breakEndTime == "--:--";

  bool get isBreakExceeded {
    if (!onActiveBreak) return false;
    final now = DateTime.now();
    if (_localBreakStart == null) return false;
    final duration = now.difference(_localBreakStart!);
    return duration.inMinutes >= 59;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _cameraService = CameraService();
    _audioPlayer = AudioPlayer();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      final appController = Provider.of<AppController>(context, listen: false);
      if (appController.userPhoto != null) {
        setState(() {});
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

    _loadInitialData().then((_) {
      _restoreTimerStates();
    });

    _startLiveUpdates();
    _startBreakAlertCheck();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _sendTokenIfNeeded();
    });
  }

  Future<void> _sendTokenIfNeeded() async {
    try {
      if (widget.uid.isNotEmpty) {
        // لا نستخدم القيمة المرجعة، فقط نتحقق من عدم حدوث خطأ
        await NotificationService().sendTokenIfNeeded(widget.uid);
        print('✅ تم إرسال FCM Token للمستخدم ${widget.uid} عند فتح لوحة التحكم');
      }
    } catch (e) {
      print('⚠️ فشل إرسال FCM Token: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      _forceCloseCamera();
      _audioPlayer.stop();
      _cacheTimerStates();
    } else if (state == AppLifecycleState.resumed) {
      _startBreakAlertCheck();
    }
  }

  @override
  void dispose() {
    _updateTimer?.cancel();
    _breakAlertTimer?.cancel();
    _forceCloseCamera();
    _audioPlayer.dispose();
    liveWorkTimeN.dispose();
    liveBreakTimeN.dispose();
    _loadingAnimationController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

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

  Future<void> _clearBreakStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${widget.uid}_break_start');
    } catch (e) {
      print('❌ خطأ في مسح وقت الاستراحة: $e');
    }
  }

  Future<void> _clearWorkStart() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('${widget.uid}_work_start');
    } catch (e) {
      print('❌ خطأ في مسح وقت العمل: $e');
    }
  }

  void onBottomTap(int index) => AppNav.go(context, index, current: 0, uid: widget.uid, name: widget.name, role: widget.role, photo: _photoUrl);

  Future<void> _loadInitialData() async {
    await Future.wait([loadToday(), loadMonth()]);
  }

  Future<void> _loadOuting() async {
    try {
      final r = await ApiService.post({'action': 'outing_today'});
      if (!mounted || r['success'] != true) return;
      setState(() {
        _outingPending = (r['pending'] as Map?)?.cast<String, dynamic>();
        _outingActive = (r['active'] as Map?)?.cast<String, dynamic>();
      });
    } catch (_) {}
  }

  /// In-shift location follow-up (Android keeps it running in the background).
  void _syncTracker() {
    if (checkedIn && !dayFinished) {
      ShiftTracker.instance.start(JphBridge.api,
          notifTitle: 'Value Attendance — الحضور شغال',
          notifText: 'بنسجّل مكانك أثناء الشيفت بس، والتتبع بيقف لوحده بعد الانصراف');
    } else {
      ShiftTracker.instance.stop();
    }
  }

  Future<void> loadToday() async {
    _loadOuting();
    try {
      _isRefreshing = true;
      if (mounted) setState(() {});

      final res = await DashboardApi.today(widget.uid);
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
        _syncTracker();
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

  Future<void> loadMonth() async {
    try {
      final res = await DashboardApi.month(widget.uid);
      if (!mounted) return;

      if (res["success"] == true) {
        setState(() => monthData = res);
      }
    } catch (e) {
      // تجاهل الأخطاء
    }
  }

  void _startLiveUpdates() {
    _updateTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (checkedIn && mounted) {
        liveWorkTimeN.value = _calcWorkTime();
      }
      if (state.onBreak && mounted) {
        liveBreakTimeN.value = _calcBreakTime();
      }
      // approved return time passed: ring once and ask for an action
      final a = _outingActive;
      if (mounted && a != null && _outingOverdue && _overdueRungFor != a['id'] && !_outingDialogOpen) {
        _overdueRungFor = a['id']?.toString();
        _playBellSound();
        _openOutingActions(overdue: true);
      }
    });
  }

  void _startBreakAlertCheck() {
    _breakAlertTimer?.cancel();
    _breakAlertTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && onActiveBreak && isBreakExceeded && !_showBreakAlert) {
        setState(() {
          _showBreakAlert = true;
        });

        if (!_hasPlayedSound) {
          _playBellSound();
          _hasPlayedSound = true;
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            showBreakAlertDialog(
              context: context,
              state: state,
              liveBreakTimeN: liveBreakTimeN,
              isBreakExceeded: isBreakExceeded,
              stopSound: _stopSound,
              executeEndBreak: _executeEndBreak,
              autoShow: true,
            );
          }
        });
      }
    });
  }

  Future<void> _playBellSound() async {
    try {
      await _audioPlayer.play(AssetSource('sounds/bell_sound.WAV'));

      for (int i = 0; i < 2; i++) {
        await Future.delayed(const Duration(milliseconds: 500));
        await _audioPlayer.play(AssetSource('sounds/bell_sound.WAV'));
      }
    } catch (e) {
      print('Error playing sound: $e');
      await _audioPlayer.play(AssetSource('sounds/notification.WAV'));
    }
  }

  Future<void> _stopSound() async {
    await _audioPlayer.stop();
    _hasPlayedSound = false;
  }

  String _calcWorkTime() {
    if (!checkedIn) return "--:--:--";

    if (_localWorkStart == null) {
      _localWorkStart = DateTime.now();
      return "00:00:01";
    }

    final now = DateTime.now();
    final difference = now.difference(_localWorkStart!);
    final totalSeconds = difference.inSeconds;
    if (totalSeconds <= 0) return "00:00:01";

    return _fmt(difference);
  }

  String _calcBreakTime() {
    if (!state.onBreak) {
      return (sheetData["breakTime"] ?? "--:--").toString();
    }

    if (_localBreakStart == null) {
      _localBreakStart = DateTime.now();
      return "00:00:01";
    }

    final now = DateTime.now();
    final difference = now.difference(_localBreakStart!);
    final totalSeconds = difference.inSeconds;
    if (totalSeconds <= 0) return "00:00:01";

    return _fmt(difference);
  }

  void _initializeLocalTimers() {
    if (checkedIn && _localWorkStart == null) {
      _localWorkStart = DateTime.now();
    } else if (!checkedIn) {
      _localWorkStart = null;
    }

    if (onActiveBreak && _localBreakStart == null) {
      _localBreakStart = DateTime.now();
    } else if (!state.onBreak) {
      _localBreakStart = null;
    }
  }

  String _fmt(Duration d) {
    final totalSeconds = d.inSeconds;
    if (totalSeconds <= 0) return "00:00:01";

    final h = d.inHours.toString().padLeft(2, "0");
    final m = (d.inMinutes % 60).toString().padLeft(2, "0");
    final s = (d.inSeconds % 60).toString().padLeft(2, "0");
    return "$h:$m:$s";
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
        if (_outingActive != null) {
          return FingerUiConfig(
            title: _outingOverdue ? 'ميعاد الرجوع عدّى' : 'تم العودة',
            subtitle: _outingOverdue ? 'سجّل رجوعك أو اطلب تمديد' : 'اضغط مطولاً لما ترجع المكتب',
            color: _outingOverdue ? Colors.orange : getSecondaryColor(),
            iconBg: _outingOverdue ? Colors.orange : getSecondaryColor(),
          );
        }
        if (sheetData['attendanceExempt'] == true) {
          return FingerUiConfig(
            title: 'ليس لديه حضور وانصراف',
            subtitle: 'حسابك مش محتاج بصمة',
            disabled: true,
            color: Colors.grey,
            iconBg: Colors.grey,
          );
        }
        if (dayFinished) {
          return FingerUiConfig(
            title: AppLocalizations.of(context, 'work_day_ended'),
            subtitle: "تم انتهاء يوم العمل",
            disabled: true,
            color: getPrimaryColor(),
            iconBg: getPrimaryColor(),
          );
        }
        if (checkedIn && onActiveBreak) {
          if (isBreakExceeded) {
            return FingerUiConfig(
              title: AppLocalizations.of(context, 'break_exceeded_alert'),
              subtitle: "انتهِ من الاستراحة أولاً",
              disabled: false,
              color: Colors.orange,
              iconBg: Colors.orange,
            );
          }
          return FingerUiConfig(
            title: AppLocalizations.of(context, 'end_break_first'),
            subtitle: "انتهِ من الاستراحة أولاً",
            disabled: false,
            color: getSecondaryColor(),
            iconBg: getSecondaryColor(),
          );
        }
        if (checkedIn) {
          return FingerUiConfig(
            title: AppLocalizations.of(context, 'check_out'),
            subtitle: "تسجيل انتهاء العمل",
            color: getErrorColor(),
            iconBg: getErrorColor(),
          );
        }
        return FingerUiConfig(
          title: AppLocalizations.of(context, 'check_in'),
          subtitle: "تسجيل بداية العمل",
          color: getPrimaryColor(),
          iconBg: getPrimaryColor(),
        );

      case DashMode.breakTime:
        if (dayFinished) {
          return FingerUiConfig(
            title: AppLocalizations.of(context, 'work_day_ended'),
            subtitle: "تم انتهاء يوم العمل",
            disabled: true,
            color: getPrimaryColor(),
            iconBg: getPrimaryColor(),
          );
        }
        // a permission works even before checking in (e.g. coming late with permission)
        if (_outingPending != null) {
          return FingerUiConfig(
            title: 'بانتظار الموافقة',
            subtitle: _outingPending!['parent_id'] != null ? 'طلب التمديد عند المدير / الموارد البشرية' : 'الطلب عند المدير / الموارد البشرية',
            disabled: true,
            color: getAccentColor(),
            iconBg: getAccentColor(),
          );
        }
        if (_outingActive != null) {
          return FingerUiConfig(
            title: _outingOverdue ? 'ميعاد الرجوع عدّى' : 'تم العودة',
            subtitle: _outingOverdue ? 'سجّل رجوعك أو اطلب تمديد' : 'اضغط مطولاً لما ترجع المكتب',
            color: _outingOverdue ? Colors.orange : getSecondaryColor(),
            iconBg: _outingOverdue ? Colors.orange : getSecondaryColor(),
          );
        }
        return FingerUiConfig(
          title: 'إذن ساعات / زيارة',
          subtitle: "اضغط مطولاً للاختيار",
          color: getAccentColor(),
          iconBg: getAccentColor(),
        );

      case DashMode.leave:
        return FingerUiConfig(
          title: AppLocalizations.of(context, 'request_leave'),
          subtitle: "طلب إجازة أو إذن",
          color: getPrimaryColor(),
          iconBg: getPrimaryColor(),
        );
    }
  }

  StatRightCardModel _getRightCard(BuildContext context) {
    switch (mode) {
      case DashMode.breakTime:
        final o = _outingActive ?? _outingPending;
        String hhmm(Object? iso) {
          final d = DateTime.tryParse('$iso')?.toLocal();
          return d == null ? '--:--' : '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
        }
        return StatRightCardModel.outing(
          kind: o == null ? '--' : (o['kind'] == 'visit' ? 'زيارة' : 'إذن ساعات'),
          start: o == null ? '--:--' : hhmm(o['starts_at'] ?? o['requested_at']),
          expectedReturn: o == null ? '--:--' : hhmm(o['expected_return_at']),
          returnAt: _outingActive == null ? null : DateTime.tryParse('${_outingActive!['expected_return_at']}')?.toLocal(),
        );
      case DashMode.leave:
        return StatRightCardModel.leave(
          leaveDays: (monthData["leaveDays"] ?? "0").toString(),
          leaveAttendance: (monthData["leaveAttendance"] ?? "0").toString(),
          sickLeave: (monthData["sickLeave"] ?? "0").toString(),
        );

      case DashMode.check:
      default:
        return StatRightCardModel.check(
          checkTime: state.checkInTime,
          checkOutTime: state.checkOutTime,
          workTime: checkedIn ? liveWorkTimeN.value : ((sheetData["workTime"] ?? "--:--") as String),
        );
    }
  }

  void setTab(DashMode m) => setState(() => mode = m);

  Future<void> onFingerSuccess() async {
    final currentContext = context;
    final config = _getFingerConfig(currentContext);

    if (config.disabled || _cameraInUse) return;

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

    if (mode == DashMode.breakTime || (mode == DashMode.check && _outingActive != null)) {
      await _handleOuting();
      return;
    }

    if (mode == DashMode.check && onActiveBreak) {
      await showBreakAlertDialog(
        context: currentContext,
        state: state,
        liveBreakTimeN: liveBreakTimeN,
        isBreakExceeded: isBreakExceeded,
        stopSound: _stopSound,
        executeEndBreak: _executeEndBreak,
        autoShow: false,
      );
      return;
    }

    _cameraInUse = true;

    try {
      Map<String, dynamic> res;

      if (mode == DashMode.check) {
        final capture = await _obtainCapture(currentContext);
        if (capture == null) {
          _cameraInUse = false;
          return;
        }

        res = await DashboardApi.checkIn(
          widget.uid,
          widget.name,
          image: capture.base64,
          location: capture.location,
          uploadId: capture.uploadId,
        );
      } else if (mode == DashMode.breakTime && checkedIn) {
        if (dayFinished) {
          ScaffoldMessenger.of(currentContext).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(currentContext, 'work_day_ended')),
              backgroundColor: Colors.orange,
            ),
          );
          _cameraInUse = false;
          return;
        }

        if (!state.onBreak) {
          res = await DashboardApi.breakStart(widget.uid);
          if (res["success"] == true) {
            _localBreakStart = DateTime.now();
            await _cacheTimerStates();
          }
        } else {
          res = await DashboardApi.breakEnd(widget.uid);
          if (res["success"] == true) {
            await _clearBreakStart();
            _localBreakStart = null;
          }
        }
      } else {
        _cameraInUse = false;
        return;
      }

      if (!mounted) {
        _cameraInUse = false;
        return;
      }

      if (res["success"] == true) {
        // Confirmed success: the photo is attached server-side, so the retained
        // capture is spent and must not be reused for a later check-in.
        if (mode == DashMode.check) _pendingCaptures.clear();

        await Future.wait([loadToday(), loadMonth()]);

        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(
            content: Text(res["message"] ?? AppLocalizations.of(currentContext, 'operation_success')),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(currentContext).showSnackBar(
          SnackBar(
            content: Text(res["message"] ?? AppLocalizations.of(currentContext, 'operation_failed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(currentContext).showSnackBar(
        SnackBar(
          content: Text("${AppLocalizations.of(currentContext, 'error_occurred')}: ${e.toString()}"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _cameraInUse = false;
    }
  }

  // ------------------------------------------------------------------ permission / visit
  Future<void> _handleOuting() async {
    if (_outingActive != null) {
      // before the return time: one press = "I'm back" (checked against the office location)
      if (!_outingOverdue) {
        final r = await ApiService.post({'action': 'outing_return'});
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
        await _loadOuting();
        return;
      }
      await _openOutingActions(overdue: _outingOverdue);
      return;
    }
    if (_outingPending != null) return;
    final kind = await showOutingKindPicker(context);
    if (kind == null || !mounted) return;
    await _submitOuting(kind);
  }

  Future<void> _submitOuting(String kind, {String? parentId, DateTime? currentReturn}) async {
    final form = await showOutingForm(context, kind: kind, extension: parentId != null, currentReturn: currentReturn);
    if (form == null || !mounted) return;
    final r = await ApiService.post({'action': 'outing_submit', 'kind': kind, ...form, if (parentId != null) 'parentId': parentId});
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Colors.green : Colors.red,
    ));
    await _loadOuting();
  }

  Future<void> _openOutingActions({required bool overdue}) async {
    final a = _outingActive;
    final back = _outingReturn;
    if (a == null || back == null || _outingDialogOpen) return;
    _outingDialogOpen = true;
    try {
      final choice = await showOutingActions(context, kind: '${a['kind']}', expectedReturn: back, overdue: overdue);
      await _stopSound();
      if (!mounted || choice == null) return;
      if (choice == 'return') {
        final r = await ApiService.post({'action': 'outing_return'});
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
        await _loadOuting();
      } else if (choice == 'extend') {
        await _submitOuting('${a['kind']}', parentId: '${a['id']}', currentReturn: back.isAfter(DateTime.now()) ? back : DateTime.now());
      } else if (choice == 'new') {
        // a new request starts after closing the overdue one
        await ApiService.post({'action': 'outing_return'});
        await _loadOuting();
        final kind = mounted ? await showOutingKindPicker(context) : null;
        if (kind != null && mounted) await _submitOuting(kind);
      }
    } finally {
      _outingDialogOpen = false;
    }
  }

  /// Returns the capture to attach.
  ///
  /// A fresh approved capture is reused as-is — no second camera call, no new
  /// `uploadId` — so a retry after a failed upload or check-in is recognised by
  /// the server as the same photo. Only when nothing is pending (or the pending
  /// one is stale) is a new photo taken, which correctly mints a new id.
  Future<CaptureResult?> _obtainCapture(BuildContext currentContext) async {
    final pending = _pendingCaptures.take(DateTime.now());
    if (pending != null) return pending;

    final capture = await _cameraService.captureWithLocation(currentContext);

    final approved = await Navigator.push(
      currentContext,
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => SelfiePreviewPage(imageFile: capture.file),
      ),
    );

    // Explicit cancellation: nothing is retained, so the next tap starts over.
    if (approved != true) return null;

    _pendingCaptures.put(capture, DateTime.now());
    return capture;
  }

  Future<void> _executeEndBreak() async {
    if (!onActiveBreak) return;

    _cameraInUse = true;

    try {
      final res = await DashboardApi.breakEnd(widget.uid);

      if (!mounted) {
        _cameraInUse = false;
        return;
      }

      if (res["success"] == true) {
        await Future.wait([loadToday(), loadMonth()]);

        await _clearBreakStart();
        _localBreakStart = null;

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res["message"] ?? AppLocalizations.of(context, 'operation_success')),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(res["message"] ?? AppLocalizations.of(context, 'operation_failed')),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text("${AppLocalizations.of(context, 'error_occurred')}: ${e.toString()}"),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      _cameraInUse = false;
    }
  }

  void _forceCloseCamera() {
    if (_cameraService.isInitialized) {
      _cameraService.dispose();
    }
  }

  Future<void> _handleRefresh() async {
    PerformanceScore.refresh(force: true);
    await Future.wait([loadToday(), loadMonth()]);
  }

  Widget _buildDashboardHome() {
    return SafeArea(
      child: RefreshIndicator(
        key: _refreshIndicatorKey,
        onRefresh: _handleRefresh,
        color: AppColors.primary,
        backgroundColor: Colors.transparent,
        child: Column(
          children: [
            if (_showBreakAlert && onActiveBreak && isBreakExceeded)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                decoration: BoxDecoration(
                  color: Colors.orange.withOpacity(0.9),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "تم تجاوز وقت الاستراحة! الرجاء إنهاء استراحتك.",
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.volume_up, color: Colors.white, size: 20),
                      onPressed: () async {
                        await _playBellSound();
                      },
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white, size: 20),
                      onPressed: () async {
                        await _stopSound();
                        setState(() {
                          _showBreakAlert = false;
                          _hasPlayedSound = false;
                        });
                      },
                    ),
                  ],
                ),
              ),

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
                            child: ValueListenableBuilder<String>(
                              valueListenable: (mode == DashMode.breakTime)
                                  ? liveBreakTimeN
                                  : liveWorkTimeN,
                              builder: (_, value, __) {
                                return StatRightCard(model: _getRightCard(context));
                              },
                            ),
                          ),
                        ],
                      ),

                      const SizedBox(height: 18),
                      Text(
                        AppLocalizations.of(context, 'today_time_log'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 12),
                      TodayStats(sheetData: sheetData),

                      const SizedBox(height: 16),
                      Text(
                        AppLocalizations.of(context, 'this_month'),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      MonthStats(monthData: monthData),

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

        final bool hasUnreadNotifications = appController.hasUnreadNotifications;
        final bool hasNotifications = appController.hasNotifications;

        Color notificationIconColor;
        if (hasUnreadNotifications) {
          notificationIconColor = Colors.red;
        } else if (hasNotifications) {
          notificationIconColor = Colors.orange;
        } else {
          notificationIconColor = isDark
              ? Colors.white.withOpacity(0.8)
              : AppColors.primary.withOpacity(0.8);
        }

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
              child: Stack(
                children: [
                  Container(
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
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Icon(
                          Icons.notifications,
                          size: 30,
                          color: notificationIconColor,
                        ),
                        if (_showBreakAlert && isBreakExceeded)
                          Positioned(
                            right: 8,
                            top: 8,
                            child: Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: Colors.red,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: isDark
                                      ? Colors.black.withOpacity(0.3)
                                      : Colors.white,
                                  width: 1.5,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.red.withOpacity(0.5),
                                    blurRadius: 4,
                                    spreadRadius: 1,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.circle,
                                size: 6,
                                color: Colors.white,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
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
                  _cameraService.isInitialized
                      ? AppLocalizations.of(context, 'camera_ready')
                      : AppLocalizations.of(context, 'camera_closed'),
                  style: TextStyle(
                    fontSize: 10,
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
              child: PerformanceAvatar(child: Container(
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
              )),
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
                currentIndex: 0,
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