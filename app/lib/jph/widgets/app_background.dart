import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';

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

        // 🔥 safe mode: إذا فشلت الصور، استخدم لون
        try {
          final img = isDark
              ? 'assets/bg/dark_bg.webp'
              : 'assets/bg/light_bg.webp';

          return RepaintBoundary(
            child: Stack(
              children: [
                // 1. الخلفية الأساسية
                Positioned.fill(
                  child: Image.asset(
                    img,
                    fit: BoxFit.cover,
                    filterQuality: FilterQuality.low,
                    gaplessPlayback: true,
                    errorBuilder: (context, error, stackTrace) {
                      return _fallbackBackground(isDark);
                    },
                  ),
                ),

                // 2. الـ Overlay (اختياري)
                if (showOverlay)
                  _BackgroundOverlay(isDark: isDark),

                // 3. المحتوى مع SafeArea
                Positioned.fill(
                  child: safeArea ? SafeArea(child: child) : child,
                ),
              ],
            ),
          );
        } catch (e) {
          return _fallbackBackground(isDark, child: child);
        }
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