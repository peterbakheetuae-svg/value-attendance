import 'dart:async';

import 'package:flutter/material.dart' hide Text;
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';

import '../pages/leads/leads_api.dart' show lget, ll;
import 'jph_form_ui.dart';
import 'side_sheet.dart';

/// «اختيار عميل»: a sale, a rental, a reservation or a contract is always made for an EXISTING client of the sales board —
/// the client's name and phone are never typed by hand (the server refuses a deal without a lead, whoever makes it).
/// The sheet searches the leads the user can see, by name or mobile number, and returns the chosen lead
/// ({id, fullName, phone, …}) or null.
Future<Map<String, dynamic>?> pickLeadClient(BuildContext context, bool isDark, {String title = 'اختيار عميل'}) =>
    showAppSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _LeadClientSheet(isDark: isDark, title: title),
    );

/// The field shown in a form instead of «اسم العميل» / «تليفون العميل»: the chosen client, or «اختار عميل».
Widget leadClientField(BuildContext context, bool isDark, Map<String, dynamic>? lead, ValueChanged<Map<String, dynamic>> onPick,
        {String label = 'العميل *'}) =>
    JphUi.picker(
      isDark: isDark,
      icon: Icons.person_search_rounded,
      iconColor: JphUi.primary(isDark),
      label: label,
      value: lead == null ? 'اختار عميل' : '${lead['fullName'] ?? ''}${'${lead['phone'] ?? ''}'.isEmpty ? '' : ' — ${lead['phone']}'}',
      onTap: () async {
        final v = await pickLeadClient(context, isDark);
        if (v != null) onPick(v);
      },
    );

class _LeadClientSheet extends StatefulWidget {
  final bool isDark;
  final String title;
  const _LeadClientSheet({required this.isDark, required this.title});

  @override
  State<_LeadClientSheet> createState() => _LeadClientSheetState();
}

class _LeadClientSheetState extends State<_LeadClientSheet> {
  final _q = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _rows = const [];
  bool _loading = false;
  String? _error;
  int _seq = 0;

  @override
  void dispose() {
    _debounce?.cancel();
    _q.dispose();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(v.trim()));
  }

  Future<void> _search(String q) async {
    if (q.length < 2) {
      setState(() { _rows = const []; _error = null; _loading = false; });
      return;
    }
    final mine = ++_seq;
    setState(() { _loading = true; _error = null; });
    Map<String, dynamic> r;
    try {
      r = await lget('/leads', {'q': q, 'tab': 'all', 'sort': 'name', 'size': '25'});
    } catch (_) {
      r = {'success': false};
    }
    if (!mounted || mine != _seq) return; // an older search answered late
    setState(() {
      _loading = false;
      if (r['success'] == false) {
        _rows = const [];
        _error = 'تعذر البحث — جرّب تاني';
      } else {
        _rows = ll(r['leads']);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: Container(
        constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1E1E2A) : Colors.white,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: Text(widget.title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
            IconButton(icon: const Icon(Icons.close_rounded), onPressed: () => Navigator.pop(context)),
          ]),
          const SizedBox(height: 8),
          JphUi.input(isDark: isDark, label: 'بحث بالاسم أو رقم الموبايل', controller: _q, icon: Icons.search_rounded,
              big: false, onChanged: _changed, onSubmitted: (v) => _search(v.trim())),
          const SizedBox(height: 8),
          Text('العميل لازم يكون موجود في الليدز — مينفعش تكتب بيانات عميل جديد هنا',
              style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
          const SizedBox(height: 8),
          if (_loading) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
          if (_error != null) Padding(padding: const EdgeInsets.all(12), child: Text(_error!, textAlign: TextAlign.center)),
          if (!_loading && _error == null && _q.text.trim().length >= 2 && _rows.isEmpty)
            Padding(padding: const EdgeInsets.all(16),
                child: Text('مفيش عميل بالاسم أو الرقم ده في الليدز', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _rows.length,
              itemBuilder: (_, i) {
                final l = _rows[i];
                return ListTile(
                  leading: const Icon(Icons.person_rounded),
                  title: Text('${l['fullName'] ?? ''}', style: TextStyle(fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                  subtitle: Text('${l['phone'] ?? ''}', textDirection: TextDirection.ltr, style: TextStyle(color: JphUi.sub(isDark))),
                  onTap: () => Navigator.pop(context, l),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
