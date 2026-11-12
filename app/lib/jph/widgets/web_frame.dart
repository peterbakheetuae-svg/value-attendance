import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// The website: the page background fills the whole screen (AppBackground), while the page's content keeps a
/// comfortable width in the middle and arranges itself by that width instead of stretching. Phones (and the APK)
/// are untouched: below [maxWidth] nothing changes.
class WebFrame extends StatelessWidget {
  final Widget child;
  static const double maxWidth = 1200;
  const WebFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    final mq = MediaQuery.of(context);
    if (mq.size.width <= maxWidth) return child;
    return Center(
      child: SizedBox(
        width: maxWidth,
        // the page measures its own width, not the whole screen
        child: MediaQuery(data: mq.copyWith(size: Size(maxWidth, mq.size.height)), child: child),
      ),
    );
  }
}
