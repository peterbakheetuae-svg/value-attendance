import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/jph_bridge.dart';
import 'app_menu.dart';

/// The website: the page background fills the whole screen (AppBackground), while the page's content arranges itself
/// by its own width instead of stretching. On a computer (like the «Ardena» site) a glass side bar replaces the
/// bottom bar and the page takes the rest of the screen up to [maxWidth]. Phones (and the APK) are untouched.
class WebFrame extends StatelessWidget {
  final Widget child;
  static const double maxWidth = 1480;
  static const double _gap = 14;
  const WebFrame({super.key, required this.child});

  static bool get _signedIn {
    try {
      return JphBridge.session.signedIn;
    } catch (_) {
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    final mq = MediaQuery.of(context);
    final side = _signedIn && AppMenu.wide(context);
    if (!side) {
      if (mq.size.width <= 1200) return child;
      return Center(
        child: SizedBox(width: 1200, child: MediaQuery(data: mq.copyWith(size: Size(1200, mq.size.height)), child: child)),
      );
    }
    final rest = mq.size.width - AppSidebar.width - _gap * 3;
    final w = math.min(rest, maxWidth);
    return Directionality(
      textDirection: ui.TextDirection.rtl,
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(_gap, _gap, 0, _gap),
          child: AppSidebar(active: AppMenu.activeKey(context)),
        ),
        Expanded(
          child: Center(
            child: SizedBox(
              width: w,
              // the page measures its own width, not the whole screen
              child: MediaQuery(data: mq.copyWith(size: Size(w, mq.size.height)), child: child),
            ),
          ),
        ),
      ]),
    );
  }
}
