import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import '../../widgets/glass_ui.dart';

class FingerUiConfig {
  final String title;
  final String subtitle;
  final Color color;
  final Color iconBg;
  final bool disabled;

  const FingerUiConfig({
    required this.title,
    required this.color,
    required this.iconBg,
    this.subtitle = "اضغط مطولاً للتأكيد",
    this.disabled = false,
  });

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FingerUiConfig &&
        other.title == title &&
        other.color == color &&
        other.iconBg == iconBg &&
        other.disabled == disabled &&
        other.subtitle == subtitle;
  }

  @override
  int get hashCode {
    return Object.hash(title, color, iconBg, disabled, subtitle);
  }
}

class AnimatedFingerprintAction extends StatefulWidget {
  final FingerUiConfig config;
  final Future<void> Function() onSuccess;

  const AnimatedFingerprintAction({
    super.key,
    required this.config,
    required this.onSuccess,
  });

  @override
  State<AnimatedFingerprintAction> createState() =>
      _AnimatedFingerprintActionState();
}

class _AnimatedFingerprintActionState extends State<AnimatedFingerprintAction>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;
  bool _isPressed = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 500),
      vsync: this,
    );

    _animation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _controller,
      curve: Curves.linear,
    ));

    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        _completeAction();
      }
    });
  }

  @override
  void didUpdateWidget(covariant AnimatedFingerprintAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config != widget.config) {
      _resetAnimation();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _resetAnimation() {
    _controller.reset();
    setState(() {
      _isPressed = false;
    });
  }

  void _completeAction() async {
    if (!mounted) return;

    try {
      await widget.onSuccess();
    } catch (_) {
      // تجاهل الأخطاء
    } finally {
      if (mounted) {
        _resetAnimation();
      }
    }
  }

  void _onTapDown(TapDownDetails details) {
    if (widget.config.disabled || _isPressed) return;

    setState(() {
      _isPressed = true;
    });
    _controller.forward();
  }

  void _onTapCancel() {
    _resetAnimation();
  }

  void _onTapUp(TapUpDetails details) {
    if (_controller.status != AnimationStatus.completed) {
      _resetAnimation();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.config;
    final disabled = c.disabled;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final primaryColor = disabled ? Ar.grey : c.color;
    final circleColor = primaryColor.withOpacity(0.2);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // زر البصمة
        GestureDetector(
          onTapDown: _onTapDown,
          onTapUp: _onTapUp,
          onTapCancel: _onTapCancel,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // الخلفية الأساسية
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: circleColor,
                ),
              ),

              // الدائرة المتحركة الخارجية
              AnimatedBuilder(
                animation: _animation,
                builder: (context, child) {
                  return CustomPaint(
                    size: Size(140, 140),
                    painter: _FingerprintCirclePainter(
                      progress: _animation.value,
                      color: primaryColor,
                      isPressed: _isPressed && !disabled,
                    ),
                  );
                },
              ),

              // الأيقونة الداخلية
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isDark
                      ? Colors.black.withOpacity(0.3)
                      : Colors.white.withOpacity(0.7),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  Icons.fingerprint,
                  size: 60,
                  color: primaryColor,
                ),
              ),

              // الدائرة الداخلية المتحركة
              if (_isPressed && !disabled)
                AnimatedBuilder(
                  animation: _animation,
                  builder: (context, child) {
                    return Container(
                      width: 80,
                      height: 80,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: SweepGradient(
                          colors: [
                            primaryColor.withOpacity(0.1),
                            primaryColor.withOpacity(0.3),
                            primaryColor.withOpacity(0.6),
                            primaryColor.withOpacity(0.1),
                          ],
                          stops: const [0.0, 0.25, 0.5, 0.75],
                          transform: GradientRotation(
                            2 * pi * _animation.value,
                          ),
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),

        // النص أسفل البصمة
        const SizedBox(height: 16),
        Text(
          c.title,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 16,
            color: disabled ? Colors.black38 : c.color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          disabled ? "غير متاح الآن" : c.subtitle,
          style: TextStyle(
            fontSize: 13,
            color: disabled ? Colors.black38 : Ar.grey.shade600,
          ),
        ),
      ],
    );
  }
}

class _FingerprintCirclePainter extends CustomPainter {
  final double progress;
  final Color color;
  final bool isPressed;

  _FingerprintCirclePainter({
    required this.progress,
    required this.color,
    required this.isPressed,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // رسم الدائرة الخلفية
    final backgroundPaint = Paint()
      ..color = color.withOpacity(0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;

    canvas.drawCircle(center, radius - 1.5, backgroundPaint);

    if (isPressed && progress > 0) {
      // رسم جزء التقدم
      final progressPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round;

      final sweepAngle = 2 * pi * progress;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 2),
        -pi / 2, // بدء من الأعلى
        sweepAngle,
        false,
        progressPaint,
      );

      // تأثير الوهج
      final glowPaint = Paint()
        ..color = color.withOpacity(0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 8
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);

      final glowAngle = sweepAngle + 0.1;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius - 3),
        -pi / 2,
        glowAngle,
        false,
        glowPaint,
      );
    }

    // رسم النقاط البصمة (نمط بصمة)
    if (!isPressed) {
      final dotPaint = Paint()
        ..color = color.withOpacity(0.5)
        ..style = PaintingStyle.fill;

      final dotRadius = 2.0;
      final dotCount = 12;
      final innerRadius = radius * 0.7;

      for (int i = 0; i < dotCount; i++) {
        final angle = 2 * pi * i / dotCount;
        final x = center.dx + innerRadius * cos(angle);
        final y = center.dy + innerRadius * sin(angle);

        canvas.drawCircle(Offset(x, y), dotRadius, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FingerprintCirclePainter oldDelegate) {
    return progress != oldDelegate.progress ||
        isPressed != oldDelegate.isPressed ||
        color != oldDelegate.color;
  }
}