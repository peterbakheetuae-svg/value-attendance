import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';
import '../advance_summary.dart';
import 'cash_page.dart';

/// الخزنة (كانت "ملخص المالية"): صفحة واحدة بشريط زي الصفحة الرئيسية — اسحب يمين وشمال:
///   الطلبات (الطلبات المالية بإحصائياتها) | الخزنة (الأرصدة والتحويلات والمصروفات والتحصيلات) | السجل (كل حركات الفلوس).
/// اللي ملوش صلاحية خزنة بيشوف الطلبات بس.
class CashboxHubPage extends StatelessWidget {
  final String uid;
  final String name;
  final String role;
  final int initial;
  const CashboxHubPage({super.key, required this.uid, required this.name, required this.role, this.initial = 0});

  static bool get canCash => ApiService.can('cash.hr_view') || ApiService.can('cash.office');

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final cash = canCash;
      return AppBackground(
        child: Directionality(
          textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: SafeArea(
              child: Column(children: [
                JphUi.header(context, isDark: isDark, isRTL: app.isRTL, title: cash ? 'الخزنة' : 'ملخص المالية'),
                Expanded(
                  child: SwipeTabs(
                    isDark: isDark,
                    initial: cash ? initial : 0,
                    tabs: [
                      ('الطلبات', Icons.list_alt_rounded),
                      if (cash) ('الخزنة', Icons.account_balance_wallet_rounded),
                      if (cash) ('السجل', Icons.receipt_long_rounded),
                    ],
                    pages: [
                      FinancialSummaryPage(uid: uid, name: name, role: role, embedded: true),
                      if (cash) const CashPage(embedded: true),
                      if (cash)
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1000),
                            child: CashLedgerView(isDark: isDark, can: {'office': ApiService.can('cash.office')}),
                          ),
                        ),
                    ],
                  ),
                ),
              ]),
            ),
          ),
        ),
      );
    });
  }
}
