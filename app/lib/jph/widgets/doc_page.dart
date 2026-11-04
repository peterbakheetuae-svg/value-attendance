import 'package:flutter/material.dart';
import 'app_background.dart';
import 'glass_ui_widgets.dart'; // بدلاً من glass_card.dart


class DocPage extends StatelessWidget {
  final String title;
  final String body;

  const DocPage({
    super.key,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(title),
          backgroundColor: Colors.transparent,
          elevation: 0,
        ),
        body: AppBackground(
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: GlassCard(
                child: Text(
                  body,
                  style: const TextStyle(
                    height: 1.6,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
