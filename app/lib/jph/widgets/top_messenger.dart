import 'package:flutter/material.dart';

/// Messages (SnackBars) above every page, form, bottom sheet, side panel and dialog.
///
/// A SnackBar used to be drawn by the Scaffold of the page *under* a form / sheet / dialog, so a validation error
/// («ناقص خانة») showed behind the form and the user never saw it. This puts one ScaffoldMessenger + a transparent
/// Scaffold above the Navigator: `ScaffoldMessenger.of(context)` from any page or sheet finds this one, and the pages'
/// own Scaffolds are nested in it, so the message is drawn only here — on top of everything that is open.
///
/// The keyboard: this Scaffold makes room for it (the message stays above the keyboard), and the pages under it are
/// given no keyboard inset of their own, so nothing is pushed up twice.
class TopMessenger extends StatelessWidget {
  final Widget child;
  const TopMessenger({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return ScaffoldMessenger(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: true,
        body: Builder(
          builder: (ctx) => MediaQuery.removeViewInsets(context: ctx, removeBottom: true, child: child),
        ),
      ),
    );
  }
}
