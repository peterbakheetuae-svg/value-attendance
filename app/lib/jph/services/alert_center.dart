import 'dart:async';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../pages/notifications/notifications_page.dart';
import '../widgets/outing_dialogs.dart';
import 'api_service.dart';
import 'jph_bridge.dart';
import 'notification_service.dart';
import '../../core/push.dart';

/// In-app notification center with an audible ring (no push service on the free plan):
/// polls the API while the app runs (Android keeps running in the background during a shift),
/// rings once per new actionable notification, shows it, opens the related request,
/// and stops ringing as soon as it is acknowledged (marked read).
class AlertCenter with WidgetsBindingObserver {
  AlertCenter._();
  static final AlertCenter instance = AlertCenter._();

  static const _ringing = {
    'outing_awaiting', 'outing_extension_awaiting', 'outing_overdue', 'outing_overdue_watch',
    'outing_approved', 'outing_rejected', 'outing_permission_approved_owner', 'outing_visit_approved_owner',
    'outing_extension_approved_owner', 'unauthorized_exit', 'unauthorized_exit_self', 'tracking_stopped',
    'not_checked_in', 'not_checked_out', 'checkin_reminder', 'checkout_reminder',
    'request_awaiting', 'request_approved', 'request_rejected', 'finance_awaiting', 'admin_message',
  };

  /// notification id → related record id (filled when the notifications list loads)
  static final Map<String, String> entityOf = {};

  /// Tap on a notification in the list: open the related request when there is one to act on.
  Future<void> openRelated(BuildContext ctx, String notificationId, String type) async {
    final id = entityOf[notificationId];
    if (id == null || !(type == 'outing_awaiting' || type == 'outing_extension_awaiting')) return;
    final o = await ApiService.post({'action': 'outing_get', 'id': id});
    if (o['success'] == true && ctx.mounted) {
      final m = (o['outing'] as Map).cast<String, dynamic>();
      if (m['canDecide'] == true) {
        await showOutingDecision(ctx, m, (approve, comment) => ApiService.post({'action': 'outing_decide', 'id': id, 'approve': approve, 'comment': comment}));
      }
    }
  }

  GlobalKey<NavigatorState>? _nav;
  Timer? _timer;
  final AudioPlayer _player = AudioPlayer();
  final Set<String> _seen = {};
  bool _busy = false;
  bool _showing = false;
  bool _foreground = true;
  bool _primed = false;

  void start(GlobalKey<NavigatorState> nav) {
    _nav = nav;
    if (_timer != null) return;
    WidgetsBinding.instance.addObserver(this);
    _restoreSeen();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => poll());
    Push.onMessage = poll; // a phone push while the app is open → ring + dialog now
    Future.delayed(const Duration(seconds: 3), poll);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) poll();
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
        if (!_ringing.contains(n['type'])) continue;
        await _remember('${n['id']}');
        await _alert(n);
      }
    } catch (_) {
      // offline / signed out: try again on the next tick
    } finally {
      _busy = false;
    }
  }

  Future<void> _ring() async {
    final s = await NotificationService().getNotificationSettings();
    if (s['soundEnabled'] == false) return;
    try {
      await _player.stop();
      await _player.play(AssetSource('sounds/notification.WAV'));
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
    await _ring();
    final ctx = _nav?.currentContext;
    if (ctx == null || _showing) return;
    _showing = true;
    try {
      final type = '${n['type']}';
      if ((type == 'outing_awaiting' || type == 'outing_extension_awaiting') && n['entity_id'] != null) {
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

  Future<void> _showGeneric(BuildContext ctx, Map<String, dynamic> n) async {
    final dark = Theme.of(ctx).brightness == Brightness.dark;
    final warn = '${n['type']}'.contains('unauthorized') || '${n['type']}'.contains('overdue') || '${n['type']}'.contains('stopped');
    await showDialog<void>(
      context: ctx,
      builder: (d) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        backgroundColor: dark ? Colors.grey.shade900.withOpacity(0.98) : Colors.white.withOpacity(0.98),
        insetPadding: const EdgeInsets.all(16),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Icon(warn ? Icons.warning_amber_rounded : Icons.notifications_active_rounded, size: 52, color: warn ? Colors.orange : const Color(0xFF4F46E5)),
            const SizedBox(height: 14),
            Text('${n['title']}', textAlign: TextAlign.center, style: TextStyle(fontSize: 19, fontWeight: FontWeight.bold, color: dark ? Colors.white : Colors.black)),
            if ('${n['body'] ?? ''}'.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('${n['body']}', textAlign: TextAlign.center, style: TextStyle(color: dark ? Colors.white70 : Colors.grey.shade700)),
            ],
            const SizedBox(height: 18),
            SizedBox(height: 50, child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF4F46E5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
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
