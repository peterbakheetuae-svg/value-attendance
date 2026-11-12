import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/swipe_tabs.dart';
import '../attendance/attendance_widgets.dart';
import 'cash_page.dart';
import 'payout_tabs.dart';

/// الخزنة (كانت "ملخص المالية"): صفحة واحدة بشريط زي الصفحة الرئيسية — اسحب يمين وشمال:
///   الطلبات (وتحتها: سلف | مرتبات | عمولات) | الخزنة (الأرصدة وكل أرقام الشهر، التحويلات، المصروفات، التحصيلات) | السجل.
/// فلتر الشهر فوق على الشمال زي تقرير الحضور، وبيطبق على التبويبات كلها.
/// اللي ملوش صلاحية خزنة بيشوف الطلبات بس.
class CashboxHubPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  final int initial;
  const CashboxHubPage({super.key, required this.uid, required this.name, required this.role, this.initial = 0});

  static bool get canCash => ApiService.can('cash.hr_view') || ApiService.can('cash.office');

  @override
  State<CashboxHubPage> createState() => _CashboxHubPageState();
}

class _CashboxHubPageState extends State<CashboxHubPage> {
  final _month = ValueNotifier<DateTime>(DateTime(DateTime.now().year, DateTime.now().month));

  @override
  void dispose() {
    _month.dispose();
    super.dispose();
  }

  Future<void> _filter(bool isDark) async {
    final m = await JphUi.pickMonth(context, isDark, _month.value);
    if (m != null) _month.value = m;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(builder: (context, app, _) {
      final isDark = app.isDark;
      final cash = CashboxHubPage.canCash;
      return AppBackground(
        child: Directionality(
          textDirection: app.isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Scaffold(
            backgroundColor: Colors.transparent,
            // «المالية» is a tab of the bottom bar for المالك / المدير العام and the accountant: the bar stays
            extendBody: AppNav.financeTab,
            bottomNavigationBar: AppNav.financeTab
                ? GlassBottomNav(
                    currentIndex: 5,
                    onTap: (index) => AppNav.go(context, index, current: 5, uid: widget.uid, name: widget.name, role: widget.role),
                  )
                : null,
            body: SafeArea(
              child: Column(children: [
                Header(
                  onBack: () => Navigator.pop(context),
                  onFilter: () => _filter(isDark),
                  isRTL: app.isRTL,
                  isDark: isDark,
                  title: cash ? 'المالية' : 'ملخص المالية',
                ),
                ValueListenableBuilder<DateTime>(
                  valueListenable: _month,
                  builder: (_, m, __) => Text('${JphUi.monthsAr[m.month - 1]} ${m.year}',
                      style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
                ),
                const SizedBox(height: 6),
                Expanded(
                  child: SwipeTabs(
                    isDark: isDark,
                    initial: cash ? widget.initial : 0,
                    tabs: [
                      ('الطلبات', Icons.list_alt_rounded),
                      if (cash) ('الخزنة', Icons.account_balance_wallet_rounded),
                      if (cash) ('السجل', Icons.receipt_long_rounded),
                    ],
                    pages: [
                      // الطلبات: سلف | مرتبات | عمولات (صرف ← تم الاستلام ← يتخصم من الخزنة)
                      FinanceRequestsTabs(uid: widget.uid, name: widget.name, role: widget.role, isDark: isDark, month: _month),
                      if (cash) CashPage(embedded: true, month: _month),
                      if (cash)
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 1000),
                            child: CashLedgerView(isDark: isDark, can: {'office': ApiService.can('cash.office')}, month: _month),
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
