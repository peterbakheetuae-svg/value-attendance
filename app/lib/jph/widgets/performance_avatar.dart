import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../services/api_service.dart';
import 'glass_ui.dart';

/// Monthly performance ring around the user's photo: 100% on the 1st of the month and it goes down with
/// unexcused absence, lateness, early leave and penalties; a published evaluation is averaged in.
/// The number comes from the server (GET /me/score), cached for a few minutes.
class PerformanceScore {
  static final ValueNotifier<int?> value = ValueNotifier<int?>(null);
  static DateTime? _at;

  static Future<void> refresh({bool force = false}) async {
    if (!force && _at != null && DateTime.now().difference(_at!) < const Duration(minutes: 5)) return;
    _at = DateTime.now();
    try {
      final r = await ApiService.post({'action': 'my_score'});
      if (r['success'] == true && r['score'] is num) value.value = (r['score'] as num).round();
    } catch (_) {/* keep the last value (offline) */}
  }

  static Color colorFor(int s) => s >= 80 ? const Color(0xFF2FA65A) : (s >= 50 ? Ar.amber : Ar.red);
}

class PerformanceAvatar extends StatefulWidget {
  final Widget child;
  final double size; // diameter of [child]
  final double stroke;
  const PerformanceAvatar({super.key, required this.child, this.size = 44, this.stroke = 3});

  @override
  State<PerformanceAvatar> createState() => _PerformanceAvatarState();
}

class _PerformanceAvatarState extends State<PerformanceAvatar> {
  @override
  void initState() {
    super.initState();
    PerformanceScore.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final outer = widget.size + widget.stroke * 2 + 4;
    return ValueListenableBuilder<int?>(
      valueListenable: PerformanceScore.value,
      builder: (_, score, __) => SizedBox(
        width: outer,
        height: outer,
        child: Stack(alignment: Alignment.center, children: [
          CustomPaint(
            size: Size(outer, outer),
            painter: PerformanceRingPainter(
              percent: (score ?? 100) / 100,
              stroke: widget.stroke,
              color: PerformanceScore.colorFor(score ?? 100),
              track: Ar.grey.withOpacity(0.25),
            ),
          ),
          widget.child,
        ]),
      ),
    );
  }
}

class PerformanceRingPainter extends CustomPainter {
  final double percent;
  final double stroke;
  final Color color;
  final Color track;
  PerformanceRingPainter({required this.percent, required this.stroke, required this.color, required this.track});

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = math.min(size.width, size.height) / 2 - stroke / 2;
    final base = Paint()
      ..color = track
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawCircle(c, r, base);
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), -math.pi / 2, 2 * math.pi * percent.clamp(0.0, 1.0), false, fg);
  }

  @override
  bool shouldRepaint(covariant PerformanceRingPainter old) =>
      old.percent != percent || old.color != color || old.stroke != stroke || old.track != track;
}
