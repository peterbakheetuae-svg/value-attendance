import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The glass blur on weak phones.
///
/// Every glass card blurs what is behind it (a BackdropFilter): on most phones that is cheap, but on phones with a weak
/// GPU each blur is a full extra pass and the app stutters. The page backdrop is already an out-of-focus picture, so the
/// cards look nearly the same without their own blur.
///
/// [init] watches the first frames the app draws: when the phone keeps missing the frame budget, [lowPower] turns on and
/// is remembered on that phone, and [GlassBlur] then draws its child without the blur. Fast phones keep the blur.
class GlassPerf {
  GlassPerf._();
  static const _key = 'glass_low_power_v1';

  /// true on a phone that is too slow for the blur (remembered; the web and Windows are never measured)
  static bool lowPower = false;

  static Future<void> init() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_key) == true) {
        lowPower = true;
        return;
      }
    } catch (_) {}
    final raster = <int>[];
    var seen = 0;
    late final TimingsCallback cb;
    cb = (List<ui.FrameTiming> timings) {
      for (final t in timings) {
        // the first frames include warming up (shaders, images): not counted
        if (++seen <= 40) continue;
        raster.add(t.rasterDuration.inMicroseconds);
      }
      if (raster.length < 120) return;
      SchedulerBinding.instance.removeTimingsCallback(cb);
      raster.sort();
      final median = raster[raster.length ~/ 2];
      final slow = raster.where((us) => us > 25000).length / raster.length;
      // the GPU needs more than a 60 Hz frame for half the frames, or a quarter of the frames are badly late
      if (median > 16700 || slow > 0.25) {
        lowPower = true;
        SharedPreferences.getInstance().then((p) => p.setBool(_key, true)).catchError((_) => true);
      }
    };
    SchedulerBinding.instance.addTimingsCallback(cb);
  }
}

/// A BackdropFilter that is left out on phones too slow for it ([GlassPerf.lowPower]).
class GlassBlur extends StatelessWidget {
  final ui.ImageFilter filter;
  final Widget? child;
  const GlassBlur({super.key, required this.filter, this.child});

  @override
  Widget build(BuildContext context) {
    if (GlassPerf.lowPower) return child ?? const SizedBox.shrink();
    return BackdropFilter(filter: filter, child: child);
  }
}
