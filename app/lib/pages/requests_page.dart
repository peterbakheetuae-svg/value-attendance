import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../core/async_view.dart';
import '../core/format.dart';
import '../core/i18n.dart';
import '../core/session.dart';
import '../design/app_colors.dart';
import '../design/glass.dart';
import '../design/glass_page.dart';
import '../design/primary_button.dart';
import 'common.dart';

const requestTypes = ['hourly_permission', 'short_leave', 'full_day_absence', 'emergency_permission', 'attendance_correction'];
const absenceTypes = ['annual', 'casual', 'sick', 'unpaid', 'mission'];

class RequestsPage extends StatefulWidget {
  const RequestsPage({super.key});
  @override
  State<RequestsPage> createState() => _RequestsPageState();
}

class _RequestsPageState extends State<RequestsPage> {
  String _tab = 'mine';
  Key _k = UniqueKey();

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    final tabs = <(String, String)>[
      ('mine', t('my_requests')),
      if (s.canApprove) ('awaiting', t('awaiting_my_approval')),
      if (s.has('request.read_all') || s.has('request.read_team')) ('all', s.has('request.read_all') ? t('all_requests') : t('team_requests')),
    ];
    return Stack(children: [
      RefreshIndicator(
        color: AppColors.primary,
        onRefresh: () async => setState(() => _k = UniqueKey()),
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            PageHeader(title: t('requests')),
            if (tabs.length > 1) FilterChips<String>(options: tabs, value: _tab, onChanged: (v) => setState(() { _tab = v; _k = UniqueKey(); })),
            const SizedBox(height: 12),
            RequestList(key: _k, query: {
              if (_tab == 'mine') 'scope': 'mine',
              if (_tab == 'awaiting') 'awaitingMe': '1',
            }),
            const SizedBox(height: 120),
          ]),
        ),
      ),
      PositionedDirectional(
        end: 20, bottom: 110,
        child: FloatingActionButton.extended(
          heroTag: 'new_request',
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          icon: const Icon(Icons.add),
          label: Text(t('new_request'), style: const TextStyle(fontWeight: FontWeight.w800)),
          onPressed: () async {
            final ok = await showNewRequestSheet(context);
            if (ok == true) setState(() { _tab = 'mine'; _k = UniqueKey(); });
          },
        ),
      ),
    ]);
  }
}

/// Approvals inbox opened from the dashboard.
class ApprovalsPage extends StatelessWidget {
  const ApprovalsPage({super.key});
  @override
  Widget build(BuildContext context) => GlassPage(title: t('awaiting_my_approval'), body: const RequestList(query: {'awaitingMe': '1'}));
}

class RequestList extends StatelessWidget {
  final Map<String, String> query;
  final String? employeeId;
  const RequestList({super.key, this.query = const {}, this.employeeId});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return AsyncView<Map<String, dynamic>>(
      load: () => s.api.get('/requests', {...query, if (employeeId != null) 'employeeId': employeeId}),
      builder: (ctx, d, reload) {
        final list = d.list('requests');
        if (list.isEmpty) return EmptyState(t('no_requests'));
        return Column(children: [
          for (final r in list) Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: GlassCard(
              radius: 20,
              onTap: () async {
                await Navigator.push(context, MaterialPageRoute(builder: (_) => RequestDetailPage(id: r.s('id'))));
                await reload();
              },
              child: Row(children: [
                Icon(_icon(r.s('type')), color: AppColors.primary, size: 30),
                const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(t('type_${r.s('type')}'), style: const TextStyle(fontWeight: FontWeight.w800)),
                  if (r['employee_id'] != s.id) Text(r.s('employee_name'), style: const TextStyle(fontSize: 13)),
                  Text(requestWhen(r), style: const TextStyle(fontSize: 12)),
                ])),
                StatusPill(r.s('status')),
              ]),
            ),
          ),
        ]);
      },
    );
  }

  static IconData _icon(String type) => switch (type) {
        'full_day_absence' => Icons.event_busy_rounded,
        'attendance_correction' => Icons.edit_calendar_rounded,
        'emergency_permission' => Icons.warning_amber_rounded,
        'short_leave' => Icons.directions_walk_rounded,
        _ => Icons.access_time_rounded,
      };
}

String requestWhen(Map<String, dynamic> r) {
  switch (r['type']) {
    case 'full_day_absence':
      return '${Fmt.date(r['start_date'])} → ${Fmt.date(r['end_date'])} · ${t('absence_${r['absence_type']}')} · ${t('n_days', {'n': r['days_count']})}';
    case 'attendance_correction':
      return '${Fmt.date(r['correction_date'])} · ${'${r['correction_in']}'.substring(0, 5)}${r['correction_out'] == null ? '' : ' → ${'${r['correction_out']}'.substring(0, 5)}'}';
    default:
      return '${Fmt.date(r['day'])} · ${'${r['from_time']}'.substring(0, 5)} → ${'${r['to_time']}'.substring(0, 5)} (${Fmt.minutes(r['duration_minutes'])})';
  }
}

class RequestDetailPage extends StatefulWidget {
  final String id;
  const RequestDetailPage({super.key, required this.id});
  @override
  State<RequestDetailPage> createState() => _RequestDetailPageState();
}

class _RequestDetailPageState extends State<RequestDetailPage> {
  Key _k = UniqueKey();
  bool _busy = false;

  Future<void> _decide(String decision) async {
    final comment = TextEditingController();
    final ok = await showGlassSheet<bool>(context, title: decision == 'approve' ? t('approve') : t('reject'), child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: comment, maxLines: 3, decoration: glassInput(context, decision == 'reject' ? t('rejection_reason_required') : t('comment_optional'))),
        const SizedBox(height: 16),
        PrimaryButton(label: decision == 'approve' ? t('approve') : t('reject'), color: decision == 'approve' ? AppColors.success : AppColors.error,
            onTap: () {
              if (decision == 'reject' && comment.text.trim().length < 3) { showSnack(context, t('rejection_reason_required'), error: true); return; }
              Navigator.pop(context, true);
            }),
      ],
    ));
    if (ok != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.post('/requests/${widget.id}/decision', {'decision': decision, if (comment.text.trim().isNotEmpty) 'comment': comment.text.trim()});
      if (mounted) { showSnack(context, t('saved')); setState(() => _k = UniqueKey()); }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final ok = await confirmDialog(context, title: t('cancel_request'), message: t('cancel_request_confirm'), ok: t('yes'), cancel: t('no'));
    if (!ok || !mounted) return;
    try {
      await context.read<Session>().api.post('/requests/${widget.id}/cancel');
      if (mounted) setState(() => _k = UniqueKey());
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = context.watch<Session>();
    return GlassPage(
      title: t('request_details'),
      body: AsyncView<Map<String, dynamic>>(
        key: _k,
        load: () => s.api.get('/requests/${widget.id}'),
        builder: (ctx, d, _) {
          final r = d.obj('request')!;
          final can = r.obj('can') ?? {};
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            GlassCard(child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                Expanded(child: Text(t('type_${r.s('type')}'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900))),
                StatusPill(r.s('status')),
              ]),
              const SizedBox(height: 8),
              InfoTile(title: t('employee'), value: r.s('employee_name')),
              InfoTile(title: t('when'), value: requestWhen(r)),
              InfoTile(title: t('reason'), value: r.s('reason')),
              InfoTile(title: t('route'), value: r['route'] == 'hr_only' ? t('route_hr_only') : '${t('route_manager_then_hr')} (${r.s('manager_name')})'),
              InfoTile(title: t('submitted_at'), value: Fmt.dateTime(r['created_at'])),
              if (r['attachment_id'] != null) Align(alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(icon: const Icon(Icons.attach_file), label: Text(t('attachment')),
                      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _AttachmentPage(id: r.s('attachment_id')))))),
            ])),
            SectionTitle(t('approval_history')),
            GlassCard(child: Column(children: [
              for (final a in d.list('actions'))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(a['action'] == 'approve' ? Icons.check_circle : a['action'] == 'reject' ? Icons.cancel : a['action'] == 'cancel' ? Icons.block : Icons.send_rounded,
                      color: a['action'] == 'approve' ? AppColors.success : a['action'] == 'reject' ? AppColors.error : AppColors.primary),
                  title: Text('${t('stage_${a['stage']}')} — ${t('action_${a['action']}')}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  subtitle: Text('${a['actor_name']} · ${Fmt.dateTime(a['at'])}${a['comment'] == null ? '' : '\n${a['comment']}'}'),
                ),
            ])),
            const SizedBox(height: 16),
            if (can['managerDecide'] == true || can['hrDecide'] == true)
              Row(children: [
                Expanded(child: PrimaryButton(label: t('approve'), color: AppColors.success, loading: _busy, onTap: () => _decide('approve'))),
                const SizedBox(width: 12),
                Expanded(child: PrimaryButton(label: t('reject'), color: AppColors.error, loading: _busy, onTap: () => _decide('reject'))),
              ]),
            if (can['cancel'] == true) TextButton.icon(onPressed: _cancel, icon: const Icon(Icons.block, color: AppColors.error), label: Text(t('cancel_request'), style: const TextStyle(color: AppColors.error))),
          ]);
        },
      ),
    );
  }
}

class _AttachmentPage extends StatelessWidget {
  final String id;
  const _AttachmentPage({required this.id});
  @override
  Widget build(BuildContext context) {
    final s = context.read<Session>();
    return GlassPage(title: t('attachment'), body: AsyncView<Uint8List>(
      load: () => s.api.bytes('/documents/$id'),
      builder: (ctx, bytes, _) => GlassCard(child: Image.memory(bytes, errorBuilder: (_, __, ___) => EmptyState(t('preview_unavailable')))),
    ));
  }
}

/// New request form. Duration and working days are computed by the server; the form shows its result.
Future<bool?> showNewRequestSheet(BuildContext context) {
  return showGlassSheet<bool>(context, title: t('new_request'), child: const _NewRequestForm());
}

class _NewRequestForm extends StatefulWidget {
  const _NewRequestForm();
  @override
  State<_NewRequestForm> createState() => _NewRequestFormState();
}

class _NewRequestFormState extends State<_NewRequestForm> {
  String _type = 'hourly_permission';
  String _absence = 'annual';
  DateTime? _day, _start, _end;
  TimeOfDay? _from, _to, _cin, _cout;
  final _reason = TextEditingController();
  String? _attachmentId;
  bool _busy = false;

  @override
  void dispose() { _reason.dispose(); super.dispose(); }

  bool get _hourly => _type == 'hourly_permission' || _type == 'short_leave' || _type == 'emergency_permission';

  Future<void> _attach() async {
    final s = context.read<Session>();
    try {
      final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 1600, imageQuality: 80);
      if (x == null) return;
      final bytes = await x.readAsBytes();
      final mime = x.name.toLowerCase().endsWith('.png') ? 'image/png' : 'image/jpeg';
      final r = await s.api.post('/employees/${s.id}/documents', {'mime': mime, 'fileName': x.name, 'title': t('attachment'), 'data': base64Encode(bytes)});
      setState(() => _attachmentId = r['id'] as String);
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    }
  }

  Future<void> _submit() async {
    final body = <String, dynamic>{'type': _type, 'reason': _reason.text.trim(), if (_attachmentId != null) 'attachmentId': _attachmentId};
    if (_hourly) {
      if (_day == null || _from == null || _to == null) return showSnack(context, t('fill_required'), error: true);
      body.addAll({'day': ymd(_day!), 'fromTime': hhmm(_from!), 'toTime': hhmm(_to!)});
    } else if (_type == 'full_day_absence') {
      if (_start == null || _end == null) return showSnack(context, t('fill_required'), error: true);
      body.addAll({'startDate': ymd(_start!), 'endDate': ymd(_end!), 'absenceType': _absence});
    } else {
      if (_day == null || _cin == null) return showSnack(context, t('fill_required'), error: true);
      body.addAll({'correctionDate': ymd(_day!), 'correctionIn': hhmm(_cin!), if (_cout != null) 'correctionOut': hhmm(_cout!)});
    }
    if (_reason.text.trim().length < 3) return showSnack(context, t('reason_required'), error: true);
    setState(() => _busy = true);
    try {
      await context.read<Session>().api.post('/requests', body);
      if (mounted) { showSnack(context, t('request_sent')); Navigator.pop(context, true); }
    } catch (e) {
      if (mounted) showSnack(context, errorText(e), error: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _pickBtn(String label, String? value, VoidCallback onTap, IconData icon) =>
      OutlinedButton.icon(onPressed: onTap, icon: Icon(icon), label: Text(value ?? label),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))));

  @override
  Widget build(BuildContext context) {
    final dur = (_from != null && _to != null) ? (_to!.hour * 60 + _to!.minute) - (_from!.hour * 60 + _from!.minute) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<String>(
        value: _type,
        decoration: glassInput(context, t('request_type')),
        items: [for (final x in requestTypes) DropdownMenuItem(value: x, child: Text(t('type_$x')))],
        onChanged: (v) => setState(() => _type = v ?? _type),
      ),
      const SizedBox(height: 12),
      if (_hourly) ...[
        _pickBtn(t('date'), _day == null ? null : Fmt.date(ymd(_day!)), () async { final d = await pickDate(context, initial: _day); if (d != null) setState(() => _day = d); }, Icons.event),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _pickBtn(t('from_time'), _from == null ? null : hhmm(_from!), () async { final v = await pickTime(context, initial: _from); if (v != null) setState(() => _from = v); }, Icons.schedule)),
          const SizedBox(width: 10),
          Expanded(child: _pickBtn(t('to_time'), _to == null ? null : hhmm(_to!), () async { final v = await pickTime(context, initial: _to ?? _from); if (v != null) setState(() => _to = v); }, Icons.schedule)),
        ]),
        if (dur != null) Padding(padding: const EdgeInsets.only(top: 8),
            child: Text(dur > 0 ? t('duration_is', {'d': Fmt.minutes(dur)}) : t('end_after_start'), style: TextStyle(fontWeight: FontWeight.w700, color: dur > 0 ? AppColors.success : AppColors.error))),
      ] else if (_type == 'full_day_absence') ...[
        DropdownButtonFormField<String>(
          value: _absence,
          decoration: glassInput(context, t('absence_type')),
          items: [for (final x in absenceTypes) DropdownMenuItem(value: x, child: Text(t('absence_$x')))],
          onChanged: (v) => setState(() => _absence = v ?? _absence),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _pickBtn(t('start_date'), _start == null ? null : Fmt.date(ymd(_start!)), () async { final d = await pickDate(context, initial: _start); if (d != null) setState(() { _start = d; if (_end == null || _end!.isBefore(d)) _end = d; }); }, Icons.event)),
          const SizedBox(width: 10),
          Expanded(child: _pickBtn(t('end_date'), _end == null ? null : Fmt.date(ymd(_end!)), () async { final d = await pickDate(context, initial: _end ?? _start, first: _start); if (d != null) setState(() => _end = d); }, Icons.event)),
        ]),
      ] else ...[
        _pickBtn(t('date'), _day == null ? null : Fmt.date(ymd(_day!)), () async { final d = await pickDate(context, initial: _day, last: DateTime.now()); if (d != null) setState(() => _day = d); }, Icons.event),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _pickBtn(t('check_in'), _cin == null ? null : hhmm(_cin!), () async { final v = await pickTime(context, initial: _cin); if (v != null) setState(() => _cin = v); }, Icons.login)),
          const SizedBox(width: 10),
          Expanded(child: _pickBtn(t('check_out'), _cout == null ? null : hhmm(_cout!), () async { final v = await pickTime(context, initial: _cout ?? const TimeOfDay(hour: 18, minute: 0)); if (v != null) setState(() => _cout = v); }, Icons.logout)),
        ]),
      ],
      const SizedBox(height: 12),
      TextField(controller: _reason, maxLines: 3, decoration: glassInput(context, t('reason'))),
      const SizedBox(height: 8),
      Align(alignment: AlignmentDirectional.centerStart, child: TextButton.icon(
          onPressed: _attach, icon: Icon(_attachmentId == null ? Icons.attach_file : Icons.check_circle, color: _attachmentId == null ? null : AppColors.success),
          label: Text(_attachmentId == null ? t('add_attachment_optional') : t('attachment_added')))),
      const SizedBox(height: 8),
      PrimaryButton(label: t('send_request'), loading: _busy, onTap: _submit),
    ]);
  }
}
