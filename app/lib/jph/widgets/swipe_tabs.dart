import 'package:flutter/material.dart';

import 'jph_form_ui.dart';

/// One page with the home-page tab bar on top and its sections side by side: tap a tab or swipe right / left.
/// Each section keeps its state (scroll position, half-filled form) while you move between them.
class SwipeTabs extends StatefulWidget {
  final bool isDark;
  final List<(String, IconData)> tabs;
  final List<Widget> pages;
  final int initial;
  final ValueChanged<int>? onChanged;

  const SwipeTabs({super.key, required this.isDark, required this.tabs, required this.pages, this.initial = 0, this.onChanged})
      : assert(tabs.length == pages.length);

  @override
  State<SwipeTabs> createState() => _SwipeTabsState();
}

class _SwipeTabsState extends State<SwipeTabs> {
  late int _i = widget.initial.clamp(0, widget.pages.length - 1);
  late final PageController _pc = PageController(initialPage: _i);

  @override
  void dispose() {
    _pc.dispose();
    super.dispose();
  }

  void _go(int i) {
    if (i == _i) return;
    setState(() => _i = i);
    _pc.animateToPage(i, duration: const Duration(milliseconds: 280), curve: Curves.easeOutCubic);
  }

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      if (widget.tabs.length > 1)
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
          child: JphUi.tabs(widget.isDark, widget.tabs, _i, _go),
        ),
      Expanded(
        child: PageView(
          controller: _pc,
          onPageChanged: (i) {
            setState(() => _i = i);
            widget.onChanged?.call(i);
          },
          children: [for (final p in widget.pages) _KeepAlive(child: p)],
        ),
      ),
    ]);
  }
}

class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});

  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
