import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// The website on a computer: the app keeps a comfortable width (like a big tablet) centred on the screen instead of
/// stretching edge to edge — headers, tiles, the bottom bar and sheets stay in proportion. Phones (and the APK) are
/// untouched: below [maxWidth] nothing changes.
class WebFrame extends StatelessWidget {
  final Widget child;
  static const double maxWidth = 1240;
  const WebFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    if (!kIsWeb) return child;
    final mq = MediaQuery.of(context);
    final w = mq.size.width;
    if (w <= maxWidth) return child;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: dark ? const Color(0xFF070B16) : const Color(0xFFE6EAF1),
      child: Center(
        child: Container(
          width: maxWidth,
          decoration: BoxDecoration(boxShadow: [
            BoxShadow(color: Colors.black.withOpacity(dark ? 0.5 : 0.12), blurRadius: 40, spreadRadius: 2),
          ]),
          child: ClipRect(
            // the pages measure the frame, not the whole screen
            child: MediaQuery(data: mq.copyWith(size: Size(maxWidth, mq.size.height)), child: child),
          ),
        ),
      ),
    );
  }
}
