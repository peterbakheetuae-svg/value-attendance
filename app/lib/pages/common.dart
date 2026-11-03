import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';

/// ‹ March 2026 › month switcher in a glass pill.
class MonthPicker extends StatelessWidget {
  final DateTime month;
  final ValueChanged<DateTime> onChanged;
  const MonthPicker({super.key, required this.month, required this.onChanged});
  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final canNext = !DateTime(month.year, month.month + 1).isAfter(DateTime(now.year, now.month));
    return GlassCard(
      radius: 20,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(
          tooltip: t('previous_month'),
          icon: const Icon(Icons.chevron_left),
          onPressed: () => onChanged(DateTime(month.year, month.month - 1)),
        ),
        Text(Fmt.monthLabel(month), style: const TextStyle(fontWeight: FontWeight.w700)),
        IconButton(
          tooltip: t('next_month'),
          icon: const Icon(Icons.chevron_right),
          onPressed: canNext ? () => onChanged(DateTime(month.year, month.month + 1)) : null,
        ),
      ]),
    );
  }
}

/// Status → colour, shared by attendance, requests, KPI and reports.
Color statusColor(String s) {
  switch (s) {
    case 'present': case 'approved': case 'completed': case 'good': case 'published': case 'inside': return AppColors.success;
    case 'pending_manager': case 'pending_hr': case 'in_progress': case 'needs_attention': case 'draft': case 'pending': return AppColors.warning;
    case 'absent': case 'rejected': case 'below_target': case 'poor': case 'unpaid_absence': return AppColors.error;
    case 'approved_absence': case 'mission': return AppColors.secondary;
    case 'holiday': case 'weekend': return AppColors.primaryLight;
    default: return Colors.grey;
  }
}

class StatusPill extends StatelessWidget {
  final String status;
  const StatusPill(this.status, {super.key});
  @override
  Widget build(BuildContext context) => StatusChip(t('status_$status'), color: statusColor(status));
}

/// Employee photo loaded through the authenticated API (falls back to the original avatar asset).
class EmployeeAvatar extends StatefulWidget {
  final String employeeId;
  final bool hasPhoto;
  final double size;
  const EmployeeAvatar({super.key, required this.employeeId, required this.hasPhoto, this.size = 44});
  @override
  State<EmployeeAvatar> createState() => _EmployeeAvatarState();
}

class _EmployeeAvatarState extends State<EmployeeAvatar> {
  static final Map<String, Uint8List> _cache = {};
  Uint8List? _bytes;
  @override
  void initState() {
    super.initState();
    _bytes = _cache[widget.employeeId];
    if (_bytes == null && widget.hasPhoto) _load();
  }

  Future<void> _load() async {
    try {
      final b = await context.read<Session>().api.bytes('/employees/${widget.employeeId}/photo');
      _cache[widget.employeeId] = b;
      if (mounted) setState(() => _bytes = b);
    } catch (_) {/* keep default avatar */}
  }

  @override
  Widget build(BuildContext context) {
    final img = _bytes != null ? MemoryImage(_bytes!) as ImageProvider : const AssetImage('assets/avatar.png');
    return Container(
      width: widget.size, height: widget.size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.3), width: 1.5),
        image: DecorationImage(image: img, fit: BoxFit.cover),
      ),
    );
  }

  static void evict(String id) => _cache.remove(id);
}

void evictAvatar(String id) => _EmployeeAvatarState.evict(id);

/// Chips row for simple filters.
class FilterChips<T> extends StatelessWidget {
  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;
  const FilterChips({super.key, required this.options, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          for (final o in options)
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 8),
              child: ChoiceChip(
                label: Text(o.$2),
                selected: o.$1 == value,
                onSelected: (_) => onChanged(o.$1),
                selectedColor: AppColors.primary.withValues(alpha: 0.18),
                labelStyle: TextStyle(fontWeight: o.$1 == value ? FontWeight.w800 : FontWeight.w500),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
              ),
            ),
        ]),
      );
}

/// Pick a date with the app locale.
Future<DateTime?> pickDate(BuildContext context, {DateTime? initial, DateTime? first, DateTime? last}) {
  final now = DateTime.now();
  return showDatePicker(
    context: context,
    initialDate: initial ?? now,
    firstDate: first ?? DateTime(now.year - 1),
    lastDate: last ?? DateTime(now.year + 1, 12, 31),
  );
}

Future<TimeOfDay?> pickTime(BuildContext context, {TimeOfDay? initial}) =>
    showTimePicker(context: context, initialTime: initial ?? const TimeOfDay(hour: 10, minute: 0));

String ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
String hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
