import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../pages/login/otp_page.dart';
import '../services/api_service.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';
import 'app_nav.dart';
import 'glass_ui.dart';
import 'glass_ui_widgets.dart';
import 'jph_form_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

/// The disbursement code (replaces «تم الاستلام») — one mechanism for every payment:
///  • the RECIPIENT (an employee, or a marketing company signed in) sees a 4-digit code here, the moment a payment waits
///    for him (the app open) or when he opens it (a push told him — the push never carries the code);
///  • he tells it to whoever is paying, who enters it on the same OTP page as «نسيت كلمة المرور» ([PaymentVerify]).
/// The code is asked from the server on this phone only; nobody else can read it.
class PaymentCode {
  PaymentCode._();
  static bool _open = false;
  /// payments already shown in this session (a closed dialog is shown again only after the app comes back)
  static final Set<String> _shown = {};

  /// after the app comes back to the front: show again what is still waiting
  static void resumed() => _shown.clear();

  /// any payment waiting for my code → its dialog (safe to call often: on start, on resume, on a payment notification)
  static Future<void> check(GlobalKey<NavigatorState> nav) async {
    if (_open) return;
    final partner = AppNav.partner;
    final r = partner
        ? await ApiService.post({'action': 'cash_get', 'path': '/partner/payments'})
        : await ApiService.post({'action': 'payouts_list', 'scope': 'mine'});
    if (r['success'] != true) return;
    final list = ((r[partner ? 'payments' : 'payouts'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>())
        .where((p) => partner || p['awaitingMyCode'] == true).toList();
    for (final p in list) {
      final id = '${p['id']}';
      if (_shown.contains(id)) continue;
      final ctx = nav.currentContext;
      if (ctx == null || !ctx.mounted) return;
      _shown.add(id);
      await show(ctx, id, company: partner, title: partner ? '${p['what'] ?? 'صرف'}' : '${payoutKindAr(p['kind'])}',
          amount: partner ? p['amount'] : p['amount_egp'], payer: partner ? p['payerName'] : p['created_by_name']);
      return; // one at a time
    }
  }

  static String payoutKindAr(Object? k) => switch ('$k') {
        'salary' => 'المرتب',
        'advance' => 'السلفة',
        'commission' => 'العمولة',
        'work_expense' => 'مصاريف العمل',
        'fund' => 'صرف أموال',
        _ => 'صرف',
      };

  /// the code dialog of one payment
  static Future<void> show(BuildContext context, String id, {bool company = false, String title = 'صرف', Object? amount, Object? payer}) async {
    if (_open) return;
    _open = true;
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _CodeDialog(id: id, company: company, title: title, amount: amount, payer: '${payer ?? ''}'),
      );
    } finally {
      _open = false;
    }
  }
}

/// The payer's side: the OTP page (the one of «نسيت كلمة المرور») to enter the code the recipient tells him.
class PaymentVerify {
  PaymentVerify._();

  /// a payment to an employee — true when it was confirmed
  static Future<bool> payout(BuildContext context, String payoutId, {String who = 'المستلم'}) => _page(context,
      '/payouts/$payoutId/verify', 'اطلب من $who يفتح التطبيق — هيظهرله كود من 4 أرقام. اكتبه هنا وساعتها بس الصرف يتأكد ويتخصم من الخزنة.');

  /// a payment to a marketing company
  static Future<bool> expense(BuildContext context, String expenseId, {String who = 'الشركة'}) => _page(context,
      '/cash/expenses/$expenseId/verify', 'اطلب من $who تفتح التطبيق — هيظهرلها كود من 4 أرقام. اكتبه هنا وساعتها بس الصرف يتأكد ويتخصم من الخزنة.');

  static Future<bool> _page(BuildContext context, String path, String hint) async {
    final ok = await Navigator.of(context).push<bool>(MaterialPageRoute(
      builder: (_) => OtpPage(
        identifier: '',
        hint: hint,
        successHint: 'اتأكد الصرف ✅',
        showResend: false,
        verify: (code) => ApiService.post({'action': 'cash_post', 'path': path, 'body': {'code': code}, 'ok': 'اتأكد الصرف ✅'}),
      ),
    ));
    return ok == true;
  }
}

class _CodeDialog extends StatefulWidget {
  final String id, title, payer;
  final bool company;
  final Object? amount;
  const _CodeDialog({required this.id, required this.company, required this.title, required this.amount, required this.payer});

  @override
  State<_CodeDialog> createState() => _CodeDialogState();
}

class _CodeDialogState extends State<_CodeDialog> with SingleTickerProviderStateMixin {
  static const _green = Color(0xFF4FCF73);
  static const _red = Color(0xFFFF7D6E);
  String? _code;
  String? _error;
  DateTime? _expires;
  bool _busy = false;
  Timer? _tick;
  late final AnimationController _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))..forward();

  @override
  void initState() {
    super.initState();
    _get();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _enter.dispose();
    super.dispose();
  }

  Future<void> _get() async {
    setState(() { _busy = true; _error = null; });
    final path = widget.company ? '/partner/payments/${widget.id}/code' : '/payouts/${widget.id}/code';
    final r = await ApiService.post({'action': 'cash_post', 'path': path, 'body': <String, dynamic>{}, 'ok': ''});
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (r['success'] == true && '${r['code'] ?? ''}'.length == 4) {
        _code = '${r['code']}';
        _expires = DateTime.tryParse('${r['expiresAt'] ?? ''}')?.toLocal();
        HapticFeedback.mediumImpact();
      } else {
        _code = null;
        _error = '${r['message'] ?? 'مقدرناش نجيب الكود'}';
      }
    });
  }

  int get _left => _expires == null ? 0 : _expires!.difference(DateTime.now()).inSeconds.clamp(0, 3600);

  @override
  Widget build(BuildContext context) {
    final isDark = Provider.of<AppController>(context).isDark;
    final accent = isDark ? AppColors.primaryLight : AppColors.primary;
    final textMain = isDark ? Colors.white : const Color(0xFF3A1E14);
    final muted = isDark ? Colors.white60 : const Color(0xFF64748B);
    final expired = _code != null && _left == 0;
    final mm = (_left ~/ 60).toString(), ss = (_left % 60).toString().padLeft(2, '0');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(20),
        child: FadeTransition(
          opacity: CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: GlassCard(
              radius: 26,
              padding: const EdgeInsets.fromLTRB(24, 30, 24, 18),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.verified_user_rounded, color: accent, size: 40),
                const SizedBox(height: 10),
                Text('كود استلام ${widget.title}', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: textMain)),
                const SizedBox(height: 6),
                Text('${JphUi.money(widget.amount)}${widget.payer.isNotEmpty ? ' — من ${widget.payer}' : ''}', textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: accent)),
                const SizedBox(height: 8),
                Text(widget.payer.isNotEmpty ? 'قول الكود ده لـ ${widget.payer} عشان يأكد الصرف. متديهوش لحد تاني.'
                    : 'قول الكود ده للي بيصرفلك عشان يأكد الصرف. متديهوش لحد تاني.',
                    textAlign: TextAlign.center, style: TextStyle(fontSize: 14, height: 1.5, color: muted)),
                const SizedBox(height: 22),
                SizedBox(
                  height: 70,
                  child: _busy
                      ? Center(child: CircularProgressIndicator(color: accent))
                      : _code == null
                          ? Center(child: Text(_error ?? '', textAlign: TextAlign.center, style: const TextStyle(color: _red, fontWeight: FontWeight.w600)))
                          : Directionality(
                              textDirection: TextDirection.ltr,
                              child: Row(mainAxisSize: MainAxisSize.min, children: [
                                for (var i = 0; i < 4; i++) ...[
                                  if (i > 0) const SizedBox(width: 12),
                                  Container(
                                    width: 56,
                                    height: 64,
                                    alignment: Alignment.center,
                                    decoration: BoxDecoration(
                                      color: isDark ? Colors.white.withOpacity(0.10) : Colors.white.withOpacity(0.55),
                                      borderRadius: BorderRadius.circular(14),
                                      border: Border.all(color: expired ? _red : accent, width: 1.5),
                                      boxShadow: [if (!expired) BoxShadow(color: accent.withOpacity(0.25), spreadRadius: 3)],
                                    ),
                                    child: Text(_code![i],
                                        style: TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: expired ? muted : textMain)),
                                  ),
                                ],
                              ]),
                            ),
                ),
                const SizedBox(height: 10),
                if (_code != null)
                  Text(expired ? 'الكود خلص وقته — اطلب كود جديد' : 'صالح لمدة $mm:$ss',
                      style: TextStyle(color: expired ? _red : _green, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: _busy ? null : _get,
                  child: Text('كود جديد', style: TextStyle(color: accent, fontWeight: FontWeight.w700)),
                ),
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    ),
                    child: const Text('تمام', style: TextStyle(fontWeight: FontWeight.w800)),
                  ),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

/// the button that opens the code (recipient) or the code entry (payer), for the lists of payments
Widget paymentCodeButton(BuildContext context, {required bool mine, required String id, required String title, Object? amount, Object? payer,
    String who = 'المستلم', bool company = false, Future<void> Function()? after}) {
  return SizedBox(
    width: double.infinity,
    child: ElevatedButton.icon(
      onPressed: () async {
        if (mine) {
          await PaymentCode.show(context, id, company: company, title: title, amount: amount, payer: payer);
        } else {
          company ? await PaymentVerify.expense(context, id, who: who) : await PaymentVerify.payout(context, id, who: who);
        }
        if (after != null) await after();
      },
      icon: Icon(mine ? Icons.pin_rounded : Icons.password_rounded, size: 18),
      label: Text(mine ? 'اعرض كود الاستلام' : 'اكتب كود الاستلام', style: const TextStyle(fontWeight: FontWeight.w800)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Ar.green,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
