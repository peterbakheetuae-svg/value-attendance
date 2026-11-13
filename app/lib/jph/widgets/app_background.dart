import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import 'web_frame.dart';
import 'glass_ui.dart';

class AppBackground extends StatelessWidget {
  final Widget child;
  final bool showOverlay;
  final bool safeArea;

  const AppBackground({
    super.key,
    required this.child,
    this.showOverlay = true,
    this.safeArea = true,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;

        // the «Ardena» backdrop: a soft out-of-focus room under a dark / light veil (one look for every page)
        return RepaintBoundary(
          child: Stack(
            children: [
              Positioned.fill(child: AppBackdrop(isDark: isDark)),
              // the website: the background fills the screen, the content keeps its width in the middle
              Positioned.fill(
                child: WebFrame(child: safeArea ? SafeArea(child: child) : child),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _fallbackBackground(bool isDark, {Widget? child}) {
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
      child: child,
    );
  }
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