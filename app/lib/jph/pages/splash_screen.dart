import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../services/session_service.dart';
import '../services/update_service.dart';
import 'login/login_page.dart';
import 'dashboard_employers/dashboard_page.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_ui.dart';
import '../widgets/logo_orbit.dart';

class SplashScreen extends StatefulWidget {
  final int splashDuration;
  final String? imagePath;
  final bool showOverlay;
  final bool safeArea;

  const SplashScreen({
    super.key,
    this.splashDuration = 2, // قللت المدة الافتراضية إلى 2 ثانية
    this.imagePath,
    this.showOverlay = true,
    this.safeArea = false,
  });

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {

  late AnimationController _rotationController;
  late Animation<double> _fadeAnimation;
  late Animation<double> _scaleAnimation;

  bool _isLoading = true;
  Timer? _navigationTimer;
  Map<String, dynamic>? _session;
  bool _dataLoaded = false;

  @override
  void initState() {
    super.initState();

    // إخفاء شريط الحالة
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);

    // تهيئة المتحكم في الدوران
    _rotationController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();

    // تهيئة الأنيميشنات
    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _rotationController,
        curve: const Interval(0.0, 0.6, curve: Curves.easeInOut),
      ),
    );

    _scaleAnimation = Tween<double>(
      begin: 0.5,
      end: 1.0,
    ).animate(
      CurvedAnimation(
        parent: _rotationController,
        curve: const Interval(0.3, 0.9, curve: Curves.elasticOut),
      ),
    );

    // بدء عملية التحميل
    _initializeApp();

    // مؤقت للانتقال بعد المدة المحددة أو بعد تحميل البيانات (أيهما يأتي أولاً)
    _navigationTimer = Timer(Duration(seconds: widget.splashDuration), () {
      if (_dataLoaded) {
        _navigateToNextScreen();
      } else {
        // إذا لم تنته البيانات بعد، انتظر 500ms إضافية
        Timer(const Duration(milliseconds: 500), () {
          _navigateToNextScreen();
        });
      }
    });
  }

  Future<void> _initializeApp() async {
    try {
      // تحميل بيانات الجلسة
      _session = await SessionService.get();

      // وضع علامة أن البيانات انتهت
      _dataLoaded = true;

      // التحقق من التحديثات في الخلفية (بدون انتظار)
      unawaited(_checkForUpdates());

    } catch (e) {
      print('❌ خطأ في تهيئة التطبيق: $e');
      _dataLoaded = true; // حتى في حالة الخطأ، نستمر
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      // إذا انتهى تحميل البيانات قبل انتهاء الوقت، انتقل فوراً
      if (_dataLoaded && _navigationTimer != null && !_navigationTimer!.isActive) {
        _navigateToNextScreen();
      }
    }
  }

  Future<void> _checkForUpdates() async {
    try {
      final updateInfo = await UpdateService.checkForUpdate();

      if (!mounted) return;

      if (updateInfo['success'] == false) return;

      if (updateInfo['maintenance'] == true) {
        _showMaintenanceDialog(updateInfo['maintenance_message'] ?? 'جاري الصيانة...');
      } else if (updateInfo['update_available'] == true) {
        _showUpdateDialog(updateInfo);
      }
    } catch (e) {
      print('❌ خطأ في التحقق من التحديثات: $e');
    }
  }

  void _showMaintenanceDialog(String message) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => GlassAlertDialog(
          title: const Text('الصيانة'),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => SystemNavigator.pop(),
              child: const Text('خروج'),
            ),
          ],
        ),
      );
    });
  }

  void _showUpdateDialog(Map<String, dynamic> updateInfo) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      final forceUpdate = updateInfo['latest_version']['force_update'] ?? false;

      showDialog(
        context: context,
        barrierDismissible: !forceUpdate,
        builder: (context) => GlassAlertDialog(
          title: const Text('تحديث متاح'),
          content: Text(updateInfo['latest_version']['release_notes'] ?? 'تحديث جديد متاح'),
          actions: [
            if (!forceUpdate)
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('لاحقاً'),
              ),
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _performUpdate(updateInfo);
              },
              child: const Text('تحديث الآن'),
            ),
          ],
        ),
      );
    });
  }

  Future<void> _performUpdate(Map<String, dynamic> updateInfo) async {
    try {
      final url = updateInfo['latest_version']['update_url'];

      if (url == null || url.isEmpty) {
        throw 'رابط التحديث غير متوفر';
      }

      await UpdateService.downloadAndInstallWithProgress(url, context, updateInfo);

    } catch (e) {
      print('❌ فشل التحديث: $e');
    }
  }

  void _navigateToNextScreen() {
    // إلغاء المؤقت
    _navigationTimer?.cancel();

    // إذا لم نكن mounted، لا نفعل شيئاً
    if (!mounted) return;

    // استعادة واجهة النظام قبل الانتقال
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    Widget targetScreen;

    if (_session == null) {
      targetScreen = const LoginPage();
    } else {
      final uid = _session?["uid"]?.toString();
      final name = _session?["name"]?.toString();
      final role = _session?["role"]?.toString();
      final photo = (_session?["photo"] ?? "").toString();

      if (uid == null || name == null || role == null) {
        targetScreen = const LoginPage();
      } else {
        targetScreen = DashboardPage(
          uid: uid,
          name: name,
          role: role,
          photo: photo,
        );
      }
    }

    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => targetScreen,
      ),
    );
  }

  @override
  void dispose() {
    _rotationController.dispose();
    _navigationTimer?.cancel();

    // استعادة واجهة النظام
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.edgeToEdge,
      overlays: SystemUiOverlay.values,
    );

    super.dispose();
  }

  Widget _buildBackground(bool isDark) => AppBackdrop(isDark: isDark);

  Widget _fallbackBackground(bool isDark) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isDark
              ? [Colors.black87, Ar.grey[900]!]
              : [Ar.info[50]!, Colors.white],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;

        return Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              // خلفية التطبيق المخصصة
              Positioned.fill(
                child: _buildBackground(isDark),
              ),

              // المحتوى (الدائرة والصورة) - الشكل الأصلي
              Center(
                    // the loading logo: its swoosh and squares orbit the letter
                    child: LogoOrbit(size: 200),
                  ),
            ],
          ),
        );
      },
    );
  }
}

class CirclePainter extends CustomPainter {
  final bool isDark;

  CirclePainter({this.isDark = false});

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = size.width / 2;

    // نصف دائرة برتقالية
    final orangePaint = Paint()
      ..shader = LinearGradient(
        colors: isDark
            ? [Ar.amber, Ar.amber]
            : [Ar.amber, Ar.amber],
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

    // نصف دائرة زرقاء
    final bluePaint = Paint()
      ..shader = LinearGradient(
        colors: isDark
            ? [Ar.info.shade200, Ar.info.shade400]
            : [Ar.info.shade300, Ar.info.shade700],
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

    // تأثير الوهج
    final glowPaint = Paint()
      ..color = (isDark ? Ar.info.shade200 : Ar.info).withOpacity(0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15.0);

    canvas.drawCircle(center, radius + 5, glowPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _BackgroundOverlay extends StatelessWidget {
  final bool isDark;

  const _BackgroundOverlay({required this.isDark});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
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
    );
  }
}