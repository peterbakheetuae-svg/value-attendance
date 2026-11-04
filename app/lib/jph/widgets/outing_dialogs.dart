import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../theme/app_colors.dart';

/// Hourly permission / external visit dialogs — same shell as the original break dialog
/// (rounded 24 dialog, translucent surface, circular icon badge, full-width buttons).

Widget _shell(BuildContext context, {required IconData icon, required Color color, required String title, String? subtitle, required List<Widget> children}) {
  final app = Provider.of<AppController>(context, listen: false);
  final isDark = app.isDark;
  return Directionality(
    textDirection: app.isRTL ? TextDirection.rtl : TextDirection.ltr,
    child: Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24.0)),
      backgroundColor: isDark ? Colors.grey.shade900.withOpacity(0.98) : Colors.white.withOpacity(0.98),
      insetPadding: const EdgeInsets.all(16),
      child: SingleChildScrollView(
        child: Container(
          padding: const EdgeInsets.all(24.0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24.0),
            border: Border.all(color: isDark ? Colors.white.withOpacity(0.1) : Colors.black.withOpacity(0.05)),
          ),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(
              child: Container(
                width: 84, height: 84,
                decoration: BoxDecoration(
                  color: color.withOpacity(0.1),
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withOpacity(0.3), width: 3),
                ),
                child: Icon(icon, size: 42, color: color),
              ),
            ),
            const SizedBox(height: 18),
            Text(title, textAlign: TextAlign.center,
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 14, color: isDark ? Colors.white70 : Colors.grey.shade700)),
            ],
            const SizedBox(height: 20),
            ...children,
          ]),
        ),
      ),
    ),
  );
}

Widget _button(BuildContext context, {required String label, required IconData icon, required Color color, required VoidCallback? onTap, bool outlined = false}) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: SizedBox(
      height: 52,
      child: outlined
          ? OutlinedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, color: color),
              label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 16)),
              style: OutlinedButton.styleFrom(
                side: BorderSide(color: color.withOpacity(0.5)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            )
          : ElevatedButton.icon(
              onPressed: onTap,
              icon: Icon(icon, color: Colors.white),
              label: Text(label, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: color,
                elevation: 0,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              ),
            ),
    ),
  );
}

/// Step 1: choose hourly permission or external visit. Returns 'permission' | 'visit' | null.
Future<String?> showOutingKindPicker(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (ctx) => _shell(ctx,
        icon: Icons.directions_walk_rounded,
        color: AppColors.primary,
        title: 'إذن ساعات أو زيارة',
        subtitle: 'اختار نوع الطلب',
        children: [
          _button(ctx, label: 'إذن ساعات', icon: Icons.timelapse_rounded, color: AppColors.primary, onTap: () => Navigator.pop(ctx, 'permission')),
          _button(ctx, label: 'زيارة', icon: Icons.location_city_rounded, color: AppColors.secondary, onTap: () => Navigator.pop(ctx, 'visit')),
          _button(ctx, label: 'إلغاء', icon: Icons.close_rounded, color: Colors.grey, outlined: true, onTap: () => Navigator.pop(ctx)),
        ]),
  );
}

/// Step 2: expected return time + reason (both mandatory). Returns {expectedReturn: 'HH:MM', reason}.
Future<Map<String, String>?> showOutingForm(BuildContext context, {required String kind, bool extension = false, DateTime? currentReturn}) {
  final reason = TextEditingController();
  TimeOfDay? back;
  String? error;
  final label = kind == 'visit' ? 'زيارة' : 'إذن ساعات';
  return showDialog<Map<String, String>>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final isDark = Provider.of<AppController>(ctx, listen: false).isDark;
      String two(int v) => v.toString().padLeft(2, '0');
      return _shell(ctx,
          icon: extension ? Icons.more_time_rounded : (kind == 'visit' ? Icons.location_city_rounded : Icons.timelapse_rounded),
          color: extension ? Colors.orange : AppColors.primary,
          title: extension ? 'طلب تمديد $label' : 'طلب $label',
          subtitle: extension && currentReturn != null
              ? 'ميعاد الرجوع الحالي ${two(currentReturn.hour)}:${two(currentReturn.minute)}'
              : 'كل الخانات مطلوبة',
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () async {
                final now = TimeOfDay.fromDateTime(DateTime.now().add(const Duration(minutes: 30)));
                final v = await showTimePicker(context: ctx, initialTime: back ?? now);
                if (v != null) set(() => back = v);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: 'ميعاد الرجوع المتوقع *',
                  prefixIcon: const Icon(Icons.schedule_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                  filled: true,
                  fillColor: isDark ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.6),
                ),
                child: Text(back == null ? 'اختار الساعة' : back!.format(ctx),
                    style: TextStyle(fontWeight: FontWeight.w600, color: back == null ? Colors.grey : (isDark ? Colors.white : Colors.black))),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: reason,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: extension ? 'سبب التمديد *' : 'السبب / ملاحظات *',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                filled: true,
                fillColor: isDark ? Colors.white.withOpacity(0.05) : Colors.white.withOpacity(0.6),
              ),
            ),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(error!, style: const TextStyle(color: Colors.red))),
            const SizedBox(height: 16),
            _button(ctx, label: 'إرسال للموافقة', icon: Icons.send_rounded, color: AppColors.primary, onTap: () {
              final now = DateTime.now();
              if (back == null || reason.text.trim().length < 3) {
                set(() => error = 'لازم تكتب ميعاد الرجوع والسبب (3 حروف على الأقل)');
                return;
              }
              final at = DateTime(now.year, now.month, now.day, back!.hour, back!.minute);
              if (!at.isAfter(now)) {
                set(() => error = 'ميعاد الرجوع لازم يكون بعد دلوقتي');
                return;
              }
              if (currentReturn != null && !at.isAfter(currentReturn)) {
                set(() => error = 'الميعاد الجديد لازم يكون بعد الميعاد الحالي');
                return;
              }
              Navigator.pop(ctx, {'expectedReturn': '${two(back!.hour)}:${two(back!.minute)}', 'reason': reason.text.trim()});
            }),
            _button(ctx, label: 'إلغاء', icon: Icons.close_rounded, color: Colors.grey, outlined: true, onTap: () => Navigator.pop(ctx)),
          ]);
    }),
  );
}

/// While out: "I'm back" / extension / (overdue) new request. Returns 'return' | 'extend' | 'new' | null.
Future<String?> showOutingActions(BuildContext context, {required String kind, required DateTime expectedReturn, required bool overdue}) {
  String two(int v) => v.toString().padLeft(2, '0');
  final label = kind == 'visit' ? 'زيارة' : 'إذن ساعات';
  return showDialog<String>(
    context: context,
    barrierDismissible: !overdue,
    builder: (ctx) => _shell(ctx,
        icon: overdue ? Icons.notifications_active_rounded : Icons.directions_walk_rounded,
        color: overdue ? Colors.orange : AppColors.secondary,
        title: overdue ? 'ميعاد رجوعك عدّى ⏰' : 'إنت في $label',
        subtitle: 'ميعاد الرجوع ${two(expectedReturn.hour)}:${two(expectedReturn.minute)}',
        children: [
          _button(ctx, label: 'رجعت المكتب', icon: Icons.login_rounded, color: AppColors.success, onTap: () => Navigator.pop(ctx, 'return')),
          _button(ctx, label: 'طلب تمديد', icon: Icons.more_time_rounded, color: Colors.orange, onTap: () => Navigator.pop(ctx, 'extend')),
          if (overdue) _button(ctx, label: 'طلب جديد (إذن / زيارة)', icon: Icons.add_rounded, color: AppColors.primary, onTap: () => Navigator.pop(ctx, 'new')),
          _button(ctx, label: 'إغلاق', icon: Icons.close_rounded, color: Colors.grey, outlined: true, onTap: () => Navigator.pop(ctx)),
        ]),
  );
}

/// Approve / reject a request (opened from a ringing notification).
Future<void> showOutingDecision(BuildContext context, Map<String, dynamic> o, Future<Map<String, dynamic>> Function(bool approve, String comment) decide) {
  final note = TextEditingController();
  final kind = o['kind'] == 'visit' ? 'زيارة' : 'إذن ساعات';
  final ext = o['parent_id'] != null;
  final back = DateTime.tryParse('${o['expected_return_at']}')?.toLocal();
  String two(int v) => v.toString().padLeft(2, '0');
  return showDialog<void>(
    context: context,
    builder: (ctx) => _shell(ctx,
        icon: ext ? Icons.more_time_rounded : Icons.directions_walk_rounded,
        color: ext ? Colors.orange : AppColors.primary,
        title: '${ext ? 'تمديد ' : ''}$kind — ${o['employee_name'] ?? ''}',
        subtitle: '${back == null ? '' : 'الرجوع ${two(back.hour)}:${two(back.minute)}\n'}${o['reason'] ?? ''}',
        children: [
          TextField(
            controller: note,
            decoration: InputDecoration(labelText: 'ملاحظة (اختياري)', border: OutlineInputBorder(borderRadius: BorderRadius.circular(16))),
          ),
          const SizedBox(height: 14),
          _button(ctx, label: 'موافقة', icon: Icons.check_rounded, color: AppColors.success, onTap: () async {
            final r = await decide(true, note.text);
            if (ctx.mounted) {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
            }
          }),
          _button(ctx, label: 'رفض', icon: Icons.close_rounded, color: AppColors.error, onTap: () async {
            final r = await decide(false, note.text);
            if (ctx.mounted) {
              Navigator.pop(ctx);
              ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(content: Text('${r['message'] ?? ''}'), backgroundColor: r['success'] == true ? Colors.green : Colors.red));
            }
          }),
          _button(ctx, label: 'لاحقاً', icon: Icons.schedule_rounded, color: Colors.grey, outlined: true, onTap: () => Navigator.pop(ctx)),
        ]),
  );
}
