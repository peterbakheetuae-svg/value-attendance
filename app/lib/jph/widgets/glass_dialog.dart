import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_controller.dart';

/// Every pop-up message in the app (drop-in for AlertDialog): the same frosted glass as the bottom bar and the
/// home cards — blurred background, translucent white / dark panel, soft white border, rounded 26.
class GlassAlertDialog extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget>? actions;
  final Widget? icon;
  // accepted for compatibility with AlertDialog; the glass look replaces them
  final ShapeBorder? shape;
  final Color? backgroundColor;

  const GlassAlertDialog({super.key, this.title, this.content, this.actions, this.icon, this.shape, this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    bool isDark;
    try {
      isDark = Provider.of<AppController>(context, listen: false).isDark;
    } catch (_) {
      isDark = Theme.of(context).brightness == Brightness.dark;
    }
    final fg = isDark ? Colors.white : const Color(0xFF1B1B1F);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(26),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(26),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? [Colors.white.withOpacity(0.16), Colors.white.withOpacity(0.07)]
                      : [Colors.white.withOpacity(0.78), Colors.white.withOpacity(0.58)],
                ),
                border: Border.all(color: Colors.white.withOpacity(isDark ? 0.22 : 0.6)),
                boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.18), blurRadius: 30, offset: const Offset(0, 12))],
              ),
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 12),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: fg),
                child: IconTheme.merge(
                  data: IconThemeData(color: fg),
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (icon != null) ...[Center(child: icon!), const SizedBox(height: 12)],
                    if (title != null)
                      DefaultTextStyle.merge(
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800, color: fg),
                        child: title!,
                      ),
                    if (title != null && content != null) const SizedBox(height: 12),
                    if (content != null)
                      Flexible(
                        child: SingleChildScrollView(
                          child: DefaultTextStyle.merge(style: TextStyle(fontSize: 15, height: 1.45, color: fg.withOpacity(0.92)), child: content!),
                        ),
                      ),
                    if (actions != null && actions!.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, overflowAlignment: OverflowBarAlignment.end, children: actions!),
                    ],
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The glass panel alone, for custom pop-ups (drop-in for `Dialog(child: …)`).
class GlassDialogPanel extends StatelessWidget {
  final Widget child;
  final EdgeInsets insetPadding;
  // accepted for compatibility with Dialog; the glass look replaces them
  final ShapeBorder? shape;
  final Color? backgroundColor;
  const GlassDialogPanel({super.key, required this.child, this.insetPadding = const EdgeInsets.all(16), this.shape, this.backgroundColor});

  @override
  Widget build(BuildContext context) {
    bool isDark;
    try {
      isDark = Provider.of<AppController>(context, listen: false).isDark;
    } catch (_) {
      isDark = Theme.of(context).brightness == Brightness.dark;
    }
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: insetPadding,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(26),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: isDark
                    ? [Colors.white.withOpacity(0.16), Colors.white.withOpacity(0.07)]
                    : [Colors.white.withOpacity(0.78), Colors.white.withOpacity(0.58)],
              ),
              border: Border.all(color: Colors.white.withOpacity(isDark ? 0.22 : 0.6)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
