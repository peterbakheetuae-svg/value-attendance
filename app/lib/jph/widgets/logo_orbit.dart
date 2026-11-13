import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The loading logo: the «V» stays, its swoosh and the three squares orbit around it on the swoosh's own ellipse —
/// behind the letter at the top, in front of it at the bottom. Two layers cut from the supplied logo.
class LogoOrbit extends StatefulWidget {
  final double size;
  final Duration period;
  const LogoOrbit({super.key, this.size = 180, this.period = const Duration(milliseconds: 2600)});

  // the swoosh's ellipse in the picture (fractions of its side): centre, semi-axes, the long axis' direction
  static const _cx = 0.50756, _cy = 0.47419, _a = 0.42780, _b = 0.14475, _ux = 0.93453, _uy = -0.35588;

  @override
  State<LogoOrbit> createState() => _LogoOrbitState();
}

class _LogoOrbitState extends State<LogoOrbit> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: widget.period)..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// moves the swoosh by [t] radians along its ellipse: E·R(t)·E⁻¹ around the centre
  Matrix4 _orbit(double t, double s) {
    const ux = LogoOrbit._ux, uy = LogoOrbit._uy, wx = -LogoOrbit._uy, wy = LogoOrbit._ux;
    final e11 = LogoOrbit._a * ux, e21 = LogoOrbit._a * uy, e12 = LogoOrbit._b * wx, e22 = LogoOrbit._b * wy;
    final det = e11 * e22 - e12 * e21;
    final i11 = e22 / det, i12 = -e12 / det, i21 = -e21 / det, i22 = e11 / det;
    final c = math.cos(t), sn = math.sin(t);
    // R·E⁻¹
    final r11 = c * i11 - sn * i21, r12 = c * i12 - sn * i22, r21 = sn * i11 + c * i21, r22 = sn * i12 + c * i22;
    // E·R·E⁻¹
    final a11 = e11 * r11 + e12 * r21, a12 = e11 * r12 + e12 * r22, a21 = e21 * r11 + e22 * r21, a22 = e21 * r12 + e22 * r22;
    final cx = LogoOrbit._cx * s, cy = LogoOrbit._cy * s;
    final tx = cx - (a11 * cx + a12 * cy), ty = cy - (a21 * cx + a22 * cy);
    return Matrix4(a11, a21, 0, 0, a12, a22, 0, 0, 0, 0, 1, 0, tx, ty, 0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    Widget layer(String a) => Image.asset(a, width: s, height: s, filterQuality: FilterQuality.medium, gaplessPlayback: true);
    final orbit = layer('assets/images/logo_orbit.png');
    return SizedBox(
      width: s,
      height: s,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, __) {
          final m = _orbit(_c.value * 2 * math.pi, s);
          final moving = Transform(transform: m, child: orbit);
          return Stack(children: [
            moving, // the back half goes behind the letter
            layer('assets/images/logo_letter.png'),
            ClipPath(clipper: _FrontHalf(), child: moving), // the front half passes in front of it
          ]);
        },
      ),
    );
  }
}

/// everything on the near side of the ellipse's long axis (below it on screen)
class _FrontHalf extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final s = size.width;
    final c = Offset(LogoOrbit._cx * s, LogoOrbit._cy * s);
    const u = Offset(LogoOrbit._ux, LogoOrbit._uy), w = Offset(-LogoOrbit._uy, LogoOrbit._ux);
    final far = s * 3;
    return Path()
      ..moveTo((c - u * far).dx, (c - u * far).dy)
      ..lineTo((c + u * far).dx, (c + u * far).dy)
      ..lineTo((c + u * far + w * far).dx, (c + u * far + w * far).dy)
      ..lineTo((c - u * far + w * far).dx, (c - u * far + w * far).dy)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}
