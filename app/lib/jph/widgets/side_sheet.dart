import 'package:flutter/material.dart';

import 'glass_ui.dart';

/// On the computer (wide screen) forms and project / unit pages open as panels that slide in from the side
/// (like Ardena's holdings), and a panel opened from another panel opens NEXT to it — the first stays open.
/// On the phone nothing changes: bottom sheets and full pages as before.
class SideSheets {
  static const double wideFrom = 1100;
  static final List<double> _open = [];

  // the window's width (inside a panel the page sees only the panel's width, yet a panel opened from it still opens beside it)
  static bool wide(BuildContext context) => MediaQueryData.fromView(View.of(context)).size.width >= wideFrom;

  static Future<T?> show<T>(BuildContext context, {required WidgetBuilder builder, double width = 480, bool page = false}) {
    final screen = MediaQuery.of(context).size.width;
    final w = width > screen - 40 ? screen - 40 : width;
    final before = _open.fold<double>(0, (a, b) => a + b);
    final offset = before + w > screen ? (screen - w).clamp(0.0, screen) : before;
    final first = _open.isEmpty;
    _open.add(w);
    final rtl = Directionality.maybeOf(context) != TextDirection.ltr;
    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'close',
      barrierColor: Colors.black.withOpacity(first ? 0.5 : 0.25),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, _, __) {
        final d = Theme.of(ctx).brightness == Brightness.dark;
        final panel = SizedBox(
          width: w,
          height: double.infinity,
          child: Material(
            type: MaterialType.transparency,
            child: page
                // a whole page inside the panel: no side bar of its own (SidePanelScope), and it lays itself out by
                // the panel's width — not the screen's
                ? ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: SidePanelScope(
                      child: MediaQuery(data: MediaQuery.of(ctx).copyWith(size: Size(w, MediaQuery.of(ctx).size.height)), child: Builder(builder: builder)),
                    ),
                  )
                : DecoratedBox(
                    decoration: Glass.sheet(d, r: 18),
                    child: SafeArea(
                      child: Align(
                        alignment: Alignment.topCenter,
                        // the bottom-sheet content as it is (its own padding / margin / scrolling)
                        child: builder(ctx),
                      ),
                    ),
                  ),
          ),
        );
        // anchored to the screen's end side (left in Arabic), each new panel beside the ones already open
        return Padding(
          padding: EdgeInsets.fromLTRB(rtl ? 8 + offset : 0, 8, rtl ? 0 : 8 + offset, 8),
          child: Align(alignment: rtl ? Alignment.centerLeft : Alignment.centerRight, child: panel),
        );
      },
      transitionBuilder: (ctx, a, __, child) {
        final c = CurvedAnimation(parent: a, curve: Glass.ease, reverseCurve: Curves.easeIn);
        return FadeTransition(
          opacity: c,
          child: SlideTransition(position: Tween(begin: Offset(rtl ? -0.25 : 0.25, 0), end: Offset.zero).animate(c), child: child),
        );
      },
    ).whenComplete(() {
      if (_open.isNotEmpty) _open.removeLast();
    });
  }
}

/// Marks a page shown inside a side panel: the app frame (WebFrame) draws no side bar there.
class SidePanelScope extends InheritedWidget {
  const SidePanelScope({super.key, required super.child});
  static bool inPanel(BuildContext context) => context.dependOnInheritedWidgetOfExactType<SidePanelScope>() != null;
  @override
  bool updateShouldNotify(SidePanelScope oldWidget) => false;
}

/// drop-in for showModalBottomSheet: a side panel on the computer, the usual bottom sheet on the phone.
Future<T?> showAppSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  Color? backgroundColor,
  Color? barrierColor,
  BoxConstraints? constraints,
}) {
  if (SideSheets.wide(context)) return SideSheets.show<T>(context, builder: builder);
  return showModalBottomSheet<T>(
    context: context,
    builder: builder,
    isScrollControlled: isScrollControlled,
    backgroundColor: backgroundColor,
    barrierColor: barrierColor,
    constraints: constraints,
  );
}

/// open a page: a wide side panel on the computer, a normal full page on the phone.
Future<T?> pushSide<T>(BuildContext context, Widget page, {double width = 760}) {
  if (SideSheets.wide(context)) return SideSheets.show<T>(context, builder: (_) => page, width: width, page: true);
  return Navigator.push<T>(context, MaterialPageRoute(builder: (_) => page));
}
