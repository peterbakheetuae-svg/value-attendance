import '../widgets/payment_code.dart';
import 'dart:async';
import '../pages/leads/lead_page.dart';
import '../pages/leads/tasks_page.dart';
import '../widgets/side_sheet.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart' hide Text;
import '../widgets/employee_devices.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../pages/notifications/notifications_page.dart';
import '../widgets/outing_dialogs.dart';
import 'api_service.dart';
import 'jph_bridge.dart';
import 'notification_service.dart';
import '../../core/push.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_ui.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';
import '../widgets/top_banner.dart';
import '../widgets/incoming_call.dart';
import '../../core/ring_alert.dart';
import '../pages/leave_summary.dart';
import '../pages/advance_request_page.dart';
import '../pages/commissions/commissions_page.dart';
import '../pages/exclusive/exclusive_projects_page.dart' show SalesHubPage;
import '../pages/multi_company/kpi_page.dart';
import '../pages/cash/cashbox_hub_page.dart';
import '../pages/leads/leads_dashboard_page.dart';

/// In-app notification center with an audible ring (no push service on the free plan):
/// polls the API while the app runs (Android keeps running in the background during a shift),
/// rings once per new actionable notification, shows it, opens the related request,
/// and stops ringing as soon as it is acknowledged (marked read).
class AlertCenter with WidgetsBindingObserver {
  AlertCenter._();
  static final AlertCenter instance = AlertCenter._();

  /// Only these ring (full-screen + sound). Everything else is a normal notification.
  static const _ringing = {
    'outing_awaiting', 'outing_extension_awaiting', 'outing_overdue', 'outing_overdue_watch',
    'outing_approved', 'outing_rejected', 'unauthorized_exit', 'unauthorized_exit_self',
  };

  /// notification id → related record id (filled when the notifications list loads)
  static final Map<String, String> entityOf = {};

  /// Tap on a notification in the list: open the related request when there is one to act on.
  Future<void> openRelated(BuildContext ctx, String notificationId, String type) =>
      openFor(ctx, type, entityOf[notificationId], fromList: true);

  /// the icon and colour of a notification's banner, by its kind
  static (IconData, Color) _look(String type) {
    if (type.startsWith('lead_')) return (Icons.leaderboard_rounded, Glass.blue);
    if (type.startsWith('task_')) return (Icons.task_alt_rounded, Ar.info.shade700);
    if (type.startsWith('request_')) return (Icons.beach_access_rounded, Ar.green.shade700);
    if (type.startsWith('advance_') || type.startsWith('cash') || type.startsWith('payout') || type.startsWith('finance') ||
        type.startsWith('payroll')) {
      return (Icons.account_balance_wallet_rounded, Ar.amber.shade700);
    }
    if (type.startsWith('commission_')) return (Icons.workspace_premium_rounded, Ar.amber.shade700);
    if (type.startsWith('exclusive_') || type.startsWith('sale_')) return (Icons.apartment_rounded, Ar.tan.shade700);
    if (type.contains('unauthorized') || type.contains('overdue')) return (Icons.warning_amber_rounded, Ar.red.shade600);
    if (type.startsWith('checkin') || type.startsWith('checkout') || type.startsWith('attendance')) {
      return (Icons.fingerprint_rounded, Ar.info.shade700);
    }
    return (Icons.notifications_active_rounded, Glass.blue);
  }

  /// Opens what a notification is about: a lead on the sales board, the leave requests, the financial requests, the
  /// commissions, the sales, the tasks … — else the notifications page. [fromList]: tapped in the notifications page
  /// itself (nothing to open → stay there).
  Future<void> openFor(BuildContext ctx, String type, String? id, {bool fromList = false}) async {
    final s = JphBridge.session;
    final uid = s.me?['code']?.toString() ?? '', name = s.name, role = s.me?['role_name_ar']?.toString() ?? '';
    Future<void> go(Widget page) => Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => page));
    if (type.startsWith('request_')) return go(LeaveSummaryPage(uid: uid, name: name, role: role));
    if (type.startsWith('advance_') || type == 'finance_awaiting') return go(AdvanceRequestPage(uid: uid, name: name, role: role));
    if (type.startsWith('commission_')) return go(const CommissionsPage(requestsOnly: true));
    if (type.startsWith('exclusive_') || type == 'sale_awaiting') return go(const SalesHubPage());
    if (type == 'evaluation_published') return go(const KpiPage());
    if ((type.startsWith('cash') || type.startsWith('payout') || type == 'payroll_batch') && CashboxHubPage.canCash) {
      return go(CashboxHubPage(uid: uid, name: name, role: role));
    }
    if (type.startsWith('lead_') && id == null) return go(const LeadsDashboardPage());
    if (await _openSpecial(ctx, type, id)) return;
    if (!fromList && ctx.mounted) {
      await go(NotificationsPage(uid: uid, name: name, role: role));
    }
  }

  /// the leads / tasks / a new phone / a permission waiting for a decision — true when it handled the tap
  Future<bool> _openSpecial(BuildContext ctx, String type, String? id) async {
    // نظام الليدز: a lead's notification opens the lead, a task's opens the tasks
    if (type.startsWith('task_')) {
      await pushSide(ctx, const TasksPage());
      return true;
    }
    if (type.startsWith('lead_') && id != null) {
      await openLead(ctx, id);
      return true;
    }
    // a new phone waiting for approval: its employee's phones, with approve / refuse
    if (type == 'device_request' && id != null) {
      await showModalBottomSheet<void>(
        context: ctx,
        isScrollControlled: true,
        builder: (c) => SafeArea(
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SingleChildScrollView(
                  child: EmployeeDevicesBox(employeeId: id, isDark: Theme.of(c).brightness == Brightness.dark)),
            ),
          ),
        ),
      );
      return true;
    }
    if (id == null || !(type == 'outing_awaiting' || type == 'outing_extension_awaiting')) return false;
    final o = await ApiService.post({'action': 'outing_get', 'id': id});
    if (o['success'] == true && ctx.mounted) {
      final m = (o['outing'] as Map).cast<String, dynamic>();
      if (m['canDecide'] == true) {
        await showOutingDecision(ctx, m, (approve, comment) => ApiService.post({'action': 'outing_decide', 'id': id, 'approve': approve, 'comment': comment}));
      }
    }
    return true;
  }

  GlobalKey<NavigatorState>? _nav;
  Timer? _timer;
  final AudioPlayer _player = AudioPlayer();
  final Set<String> _seen = {};
  bool _busy = false;
  bool _showing = false;
  bool _foreground = true;
  bool _primed = false;

  /// A popup error (e.g. a repeated request while another one is still waiting).
  Future<void> popupError(String title, String message) async {
    final ctx = _nav?.currentContext;
    if (ctx == null) return;
    await showDialog<void>(
      context: ctx,
      builder: (c) => Directionality(
        textDirection: TextDirection.rtl,
        child: GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
          icon: const Icon(Icons.error_outline_rounded, color: Ar.red, size: 46),
          title: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w800)),
          content: Text(message, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16)),
          actions: [
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(c),
                style: ElevatedButton.styleFrom(backgroundColor: Ar.red, foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
                child: const Text('حاضر'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void start(GlobalKey<NavigatorState> nav) {
    _nav = nav;
    if (_timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    _restoreSeen();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => poll());
    Push.onMessage = poll; // a phone push while the app is open → ring + dialog now
    // «Valunivo Call»: rung while the app is open → its call screen now; rung before (opened the app / screen locked) → on start
    RingAlert.onCall = (kind) => IncomingCall.show(nav, kind);
    Future.delayed(const Duration(milliseconds: 600), () => IncomingCall.check(nav));
    Future.delayed(const Duration(seconds: 3), poll);
    // a payment waiting for my disbursement code (opened from its push, or waiting since before): its code now
    Future.delayed(const Duration(seconds: 2), () => PaymentCode.check(nav));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      // brought up by a ringing «Valunivo Call» (over the lock screen): its call screen
      final nav = _nav;
      if (nav != null) IncomingCall.check(nav);
      PaymentCode.resumed();
      if (nav != null) PaymentCode.check(nav);
      poll();
    }
  }

  Future<void> _restoreSeen() async {
    try {
      final p = await SharedPreferences.getInstance();
      _seen.addAll(p.getStringList('rung_notification_ids') ?? const []);
    } catch (_) {}
  }

  Future<void> _remember(String id) async {
    _seen.add(id);
    try {
      final p = await SharedPreferences.getInstance();
      final list = _seen.toList();
      await p.setStringList('rung_notification_ids', list.length > 300 ? list.sublist(list.length - 300) : list);
    } catch (_) {}
  }

  Future<void> poll() async {
    if (_busy || !JphBridge.session.signedIn) return;
    _busy = true;
    try {
      await _flushOffline();
      await Push.sync(JphBridge.api);
      final r = await JphBridge.api.get('/notifications', {'unread': '1'});
      final list = ((r['notifications'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
      // first poll after start: only alert about the last 10 minutes, not old unread history
      final fresh = list.where((n) {
        if (_seen.contains(n['id'])) return false;
        if (_primed) return true;
        final at = DateTime.tryParse('${n['created_at']}');
        return at != null && DateTime.now().difference(at.toLocal()).inMinutes <= 10;
      }).toList().reversed.toList();
      _primed = true;
      for (final n in list) {
        if (!_ringing.contains(n['type'])) _seen.add('${n['id']}');
      }
      for (final n in fresh) {
        // «المتابعة مش شغالة على الموبايل ده»: rung by push on the one phone of the account that sends no location —
        // never shown on the phone that is open (that one is followed already)
        if (n['type'] == 'tracking_phone_off' || n['type'] == 'checkin_other_phone') continue;
        // a payment waits for my code: the code dialog itself (not a banner) — the notification never holds the code
        if (n['type'] == 'payout_otp' || n['type'] == 'payment_otp') {
          final nav = _nav;
          if (_foreground && nav != null) await PaymentCode.check(nav);
          continue;
        }
        if (!_ringing.contains(n['type'])) {
          // normal notification: a quiet banner while the app is open (no ringing)
          // normal notification: the app's own banner at the top — swipe it away, or tap it to open what it's about
          final overlay = _nav?.currentState?.overlay;
          if (_foreground && overlay != null && overlay.mounted) {
            final type = '${n['type']}';
            final look = _look(type);
            TopBanner.show(
              overlay,
              title: '${n['title']}',
              body: '${n['body'] ?? ''}',
              icon: look.$1,
              color: look.$2,
              onTap: () async {
                final c = _nav?.currentContext;
                if (c == null || !c.mounted) return;
                try { await JphBridge.api.post('/notifications/${n['id']}/read', {}); } catch (_) {}
                if (c.mounted) await openFor(c, type, n['entity_id']?.toString());
              },
            );
          }
          continue;
        }
        await _remember('${n['id']}');
        await _alert(n);
      }
    } catch (_) {
      // offline / signed out: try again on the next tick
    } finally {
      _busy = false;
    }
  }

  /// Send what was recorded with no internet; tell the user what went through or was refused.
  Future<void> _flushOffline() async {
    final r = await JphBridge.api.flushQueue();
    final ctx = _nav?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    if (r.failed.isNotEmpty) {
      await showDialog<void>(
        context: ctx,
        builder: (d) => GlassAlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: const Text('حاجات اتسجلت أوفلاين ومااتقبلتش'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final f in r.failed) Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text('• ${f['label']}: ${f['error']}'),
            ),
          ]),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('تمام'))],
        ),
      );
    } else if (r.important > 0) {
      ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(const SnackBar(
          content: Text('النت رجع ✅ — اتبعت كل اللي اتسجل وإنت أوفلاين'), backgroundColor: Ar.green));
    }
  }

  Future<void> _ring() async {
    final s = await NotificationService().getNotificationSettings();
    if (s['soundEnabled'] == false) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/notification.mp3'));
    } catch (_) {}
  }

  Future<void> stopRinging() async {
    try { await _player.stop(); } catch (_) {}
  }

  Future<void> _alert(Map<String, dynamic> n) async {
    if (!_foreground) {
      if (Push.active) return; // the phone push already rang for this one
      // app in the background (Android shift service keeps it alive): system notification with sound
      await NotificationService().showCustomNotification(title: '${n['title']}', body: '${n['body'] ?? ''}', type: '${n['type']}');
      return;
    }
    // left the office with no permission, app open: the «Valunivo Call» screen («خرجت بدون إذن»)
    final call = RingAlert.callKind('${n['type']}');
    final nav = _nav;
    if (call != null && nav != null) {
      await IncomingCall.show(nav, call);
      try { await JphBridge.api.post('/notifications/${n['id']}/read', {}); } catch (_) {}
      return;
    }
    await _ring();
    final ctx = _nav?.currentContext;
    if (ctx == null || _showing) return;
    _showing = true;
    try {
      final type = '${n['type']}';
      if (type == 'outing_overdue') {
        await _overdue(ctx);
      } else if ((type == 'outing_awaiting' || type == 'outing_extension_awaiting') && n['entity_id'] != null) {
        final o = await ApiService.post({'action': 'outing_get', 'id': n['entity_id']});
        if (o['success'] == true && (o['outing'] as Map)['canDecide'] == true && ctx.mounted) {
          await showOutingDecision(ctx, (o['outing'] as Map).cast<String, dynamic>(),
              (approve, comment) => ApiService.post({'action': 'outing_decide', 'id': n['entity_id'], 'approve': approve, 'comment': comment}));
        }
      } else if (ctx.mounted) {
        await _showGeneric(ctx, n);
      }
    } finally {
      _showing = false;
      await stopRinging();
      // acknowledged → read (stops it from ringing again on any device)
      try { await JphBridge.api.post('/notifications/${n['id']}/read', {}); } catch (_) {}
    }
  }

  /// The return time passed: "I'm back" (checked against the office location) or ask for more time.
  Future<void> _overdue(BuildContext ctx) async {
    final t = await ApiService.post({'action': 'outing_today'});
    final active = (t['active'] as Map?)?.cast<String, dynamic>();
    final back = DateTime.tryParse('${active?['expected_return_at']}')?.toLocal();
    if (active == null || back == null || !ctx.mounted) return;
    final choice = await showOutingActions(ctx, kind: '${active['kind']}', expectedReturn: back, overdue: true);
    await stopRinging();
    if (!ctx.mounted || choice == null) return;
    if (choice == 'return') {
      final r = await ApiService.post({'action': 'outing_return'});
      if (ctx.mounted) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
            content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Ar.green : Ar.red));
      }
    } else if (choice == 'extend' || choice == 'new') {
      if (choice == 'new') await ApiService.post({'action': 'outing_return'});
      final kind = choice == 'new' ? await showOutingKindPicker(ctx) : '${active['kind']}';
      if (kind == null || !ctx.mounted) return;
      final form = await showOutingForm(ctx, kind: kind, extension: choice == 'extend',
          currentReturn: choice == 'extend' ? (back.isAfter(DateTime.now()) ? back : DateTime.now()) : null);
      if (form == null || !ctx.mounted) return;
      final r = await ApiService.post({'action': 'outing_submit', 'kind': kind, ...form, if (choice == 'extend') 'parentId': active['id']});
      if (ctx.mounted) {
        ScaffoldMessenger.maybeOf(ctx)?.showSnackBar(SnackBar(
            content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Ar.green : Ar.red));
      }
    }
  }

  Future<void> _showGeneric(BuildContext ctx, Map<String, dynamic> n) async {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    final warn = '${n['type']}'.contains('unauthorized') || '${n['type']}'.contains('overdue') || '${n['type']}'.contains('stopped');
    await showDialog<void>(
      context: ctx,
      builder: (d) => GlassDialogPanel(
        insetPadding: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Icon(warn ? Icons.warning_amber_rounded : Icons.notifications_active_rounded, size: 52, color: warn ? Ar.amber : const Color(0xFFE2501F)),
            const SizedBox(height: 14),
            Text('${n['title']}', textAlign: TextAlign.center, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: dark ? Colors.white : Colors.black)),
            if ('${n['body'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('${n['body']}', textAlign: TextAlign.center, style: TextStyle(color: dark ? Colors.white70 : Ar.grey.shade700)),
            ],
            const SizedBox(height: 18),
            SizedBox(height: 50, child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFE2501F), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: () {
                Navigator.pop(d);
                final s = JphBridge.session;
                Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => NotificationsPage(
                    uid: s.me?['code']?.toString() ?? '', name: s.name, role: s.me?['role_name_ar']?.toString() ?? '')));
              },
              child: const Text('فتح الإشعارات', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            )),
            const SizedBox(height: 8),
            SizedBox(height: 46, child: OutlinedButton(
              style: OutlinedButton.styleFrom(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
              onPressed: () => Navigator.pop(d),
              child: const Text('تمام'),
            )),
          ]),
        ),
      ),
    );
  }
}
