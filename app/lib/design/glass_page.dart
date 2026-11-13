import '../jph/widgets/side_sheet.dart';
import 'package:flutter/material.dart';
import 'app_colors.dart';
import 'glass.dart';

/// Pushed sub-page in the original look: background image, transparent scaffold,
/// back button + 22px bold title, content capped at a readable width on web/tablet.
class GlassPage extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? floating;
  final bool scroll;
  final Future<void> Function()? onRefresh;
  const GlassPage({super.key, required this.title, required this.body, this.actions = const [], this.floating, this.scroll = true, this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    Widget content = Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), child: body);
    if (scroll) {
      content = SingleChildScrollView(physics: const AlwaysScrollableScrollPhysics(), child: content);
      if (onRefresh != null) content = RefreshIndicator(onRefresh: onRefresh!, color: AppColors.primary, child: content);
    }
    return Material(
      child: AppBackground(
        safeArea: false,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: floating,
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1100),
                child: Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
                    child: Row(children: [
                      if (Navigator.of(context).canPop())
                        IconButton(
                          icon: Icon(Icons.arrow_back_rounded, color: isDark ? Colors.white : AppColors.onSurfaceLight),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      Expanded(child: PageHeader(title: title)),
                      ...actions,
                    ]),
                  ),
                  Expanded(child: content),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet in the original dialog style (glass card, radius 20).
Future<T?> showGlassSheet<T>(BuildContext context, {required String title, required Widget child}) {
  return showAppSheet<T>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: GlassCard(
              radius: 20,
              backgroundColor: isDarkOf(ctx) ? AppColors.surfaceDark.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.85),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.85),
                child: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(4)))),
                    const SizedBox(height: 12),
                    Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 16),
                    child,
                  ]),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void showSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? Colors.red : AppColors.success,
    behavior: SnackBarBehavior.floating,
  ));
}

Future<bool> confirmDialog(BuildContext context, {required String title, required String message, required String ok, required String cancel}) async {
  final r = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.5),
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.all(40),
      child: GlassCard(
        radius: 20,
        padding: const EdgeInsets.all(24),
        backgroundColor: isDarkOf(ctx) ? AppColors.surfaceDark.withValues(alpha: 0.85) : Colors.white.withValues(alpha: 0.85),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(cancel))),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(ok))),
          ]),
        ]),
      ),
    ),
  );
  return r ?? false;
}
