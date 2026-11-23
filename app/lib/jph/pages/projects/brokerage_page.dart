import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Text;
import 'package:image_picker/image_picker.dart';
import 'package:jph_real_estate_hr/jph/l10n/tx_text.dart';
import 'package:provider/provider.dart';

import '../../services/api_service.dart';
import '../../services/app_controller.dart';
import '../../services/uuid_v4.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/side_sheet.dart';
import '../../forms/unit_quote_pdf.dart' show printListingQuote;

/// «التسويق» → إعادة بيع / إيجار (server: /brokerage — 087 deals, 088 listings).
///  - Any salesperson / employee lists a property: photos, name / type, address, area, price, finishing, description.
///  - Anyone sells / rents it: the client (name, phone), the final price and the commission he took — the administrative
///    officer is told, receives the commission and sets its split (seller / lister when someone else / sales manager,
///    by amount or %; the rest to the office). The server enforces every rule.
///  - For the general manager and the administrative officer the «إضافة عقار» button sits in the page header (where
///    «إضافة مشروع» is); everyone else gets it as the floating button.

Future<Map<String, dynamic>> _get(String path, [Map<String, dynamic> query = const {}]) =>
    ApiService.post({'action': 'cash_get', 'path': path, 'query': query});
Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> body, {String? ok, bool patch = false}) =>
    ApiService.post({'action': 'cash_post', 'path': path, 'body': body, 'ok': ok, if (patch) 'method': 'patch'});
List<Map<String, dynamic>> _rows(dynamic v) => ((v as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
Map<String, dynamic> _map(dynamic v) => (v is Map) ? v.cast<String, dynamic>() : <String, dynamic>{};
num _n(dynamic v) => v is num ? v : num.tryParse('$v'.replaceAll(',', '')) ?? 0;
num? _num(TextEditingController c) => num.tryParse(c.text.trim().replaceAll(',', ''));
String _fmt(num v) {
  final whole = v == v.roundToDouble();
  final s = v.abs().toStringAsFixed(whole ? 0 : 2);
  final parts = s.split('.');
  final b = StringBuffer();
  for (var i = 0; i < parts[0].length; i++) {
    if (i > 0 && (parts[0].length - i) % 3 == 0) b.write(',');
    b.write(parts[0][i]);
  }
  return '${v < 0 ? '-' : ''}$b${parts.length > 1 ? '.${parts[1]}' : ''}';
}

String _egp(dynamic v) => '${_fmt(_n(v))} ج';

const _arrangements = [
  ('owner_month', 'شهر من المالك'),
  ('client_month', 'شهر من المستأجر'),
  ('half_each', 'نص شهر من كل طرف'),
  ('fixed', 'مبلغ ثابت متفق عليه'),
];

/// التشطيب — the five the office uses
const finishingOptions = [
  ('none', 'بدون تشطيب'),
  ('semi', 'نص تشطيب'),
  ('full', 'تشطيب كامل'),
  ('super_lux', 'سوبر لوكس'),
  ('ultra_super_lux', 'الترا سوبر لوكس'),
];
String finishingAr(String? k) => finishingOptions.firstWhere((f) => f.$1 == k, orElse: () => (k ?? '', k ?? '—')).$2;
const _types = ['شقة', 'محل', 'فيلا', 'دوبلكس', 'مكتب', 'عيادة', 'أرض', 'مخزن'];

(String, Color) _status(String? s) => switch (s) {
      'approved' => ('معتمدة — مستنية التحصيل', Glass.blue),
      'collected' => ('اتحصلت بالكامل', Colors.green),
      'rejected' => ('مرفوضة', Colors.red),
      'cancelled' => ('ملغية', Colors.grey),
      _ => ('مستنية الاعتماد', Colors.orange),
    };
(String, Color) _listingStatus(String? s, bool resale) => switch (s) {
      'pending' => ('عليه ${resale ? 'بيع' : 'إيجار'} — مستني استلام العمولة', Colors.orange),
      'sold' => (resale ? 'اتباع' : 'اتأجر', Colors.green),
      'withdrawn' => ('اتشال من العرض', Colors.grey),
      _ => ('متاح', Glass.blue),
    };

// ------------------------------------------------------------------ photos (one request each; kept for the session)
final Map<String, Future<Uint8List?>> _photoCache = {};
Future<Uint8List?> _photo(String listing, String id) => _photoCache.putIfAbsent(id, () async {
      final r = await _get('/brokerage/listings/$listing/photos/$id');
      final s = '${r['image'] ?? ''}';
      final i = s.indexOf(',');
      if (i < 0) {
        _photoCache.remove(id);
        return null;
      }
      return base64Decode(s.substring(i + 1));
    });

class _ListingPhoto extends StatelessWidget {
  final String listing, id;
  final BoxFit fit;
  const _ListingPhoto({required this.listing, required this.id, this.fit = BoxFit.cover});
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
        future: _photo(listing, id),
        builder: (_, s) => s.data == null
            ? Container(color: Colors.black12, child: s.connectionState == ConnectionState.done ? const DefaultPhoto() : const SizedBox.shrink())
            : Image.memory(s.data!, fit: fit, gaplessPlayback: true),
      );
}

/// a picked picture, ready to send: (mime, base64, bytes for the preview)
typedef _Picked = (String, String, Uint8List);

Future<List<_Picked>> _pickPhotos(BuildContext context, int room) async {
  if (room <= 0) {
    JphUi.toast(context, {'success': false, 'message': 'أقصى عدد 8 صور'});
    return const [];
  }
  List<XFile> files;
  try {
    files = await ImagePicker().pickMultiImage(imageQuality: 72, maxWidth: 1600, maxHeight: 1600);
  } catch (_) {
    files = const [];
  }
  final out = <_Picked>[];
  var big = 0;
  for (final f in files.take(room)) {
    final bytes = await f.readAsBytes();
    if (bytes.length > 1000000) {
      big++;
      continue;
    }
    final name = f.name.toLowerCase();
    final mime = name.endsWith('.png') ? 'image/png' : name.endsWith('.webp') ? 'image/webp' : 'image/jpeg';
    out.add((mime, base64Encode(bytes), bytes));
  }
  if (context.mounted && (big > 0 || files.length > room)) {
    JphUi.toast(context, {'success': false, 'message': big > 0 ? 'صورة كبيرة اتسابت — كل صورة أصغر من 1 ميجا' : 'أقصى عدد 8 صور'});
  }
  return out;
}

/// The app's form sheet (the same look as «إضافة مشروع»): glass panel, title + close, the fields, one action
Future<bool> _form(BuildContext context, bool isDark, String title, List<Widget> Function(StateSetter set) fields,
    Future<bool> Function() save, {String saveLabel = 'حفظ', IconData saveIcon = Icons.check_rounded}) async {
  var busy = false;
  final r = await showAppSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => Directionality(
      textDirection: ui.TextDirection.rtl,
      child: StatefulBuilder(
        builder: (ctx, set) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
          child: Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9),
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.all(16),
            decoration: Glass.sheet(isDark, r: 24),
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                  IconButton(onPressed: () => Navigator.pop(ctx, false), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
                ]),
                const SizedBox(height: 8),
                ...fields(set).expand((w) => [w, const SizedBox(height: 10)]),
                const SizedBox(height: 6),
                _btn(isDark, busy ? 'لحظة…' : saveLabel, saveIcon, busy
                    ? null
                    : () async {
                        set(() => busy = true);
                        final done = await save();
                        if (!ctx.mounted) return;
                        set(() => busy = false);
                        if (done) Navigator.pop(ctx, true);
                      }),
              ]),
            ),
          ),
        ),
      ),
    ),
  );
  return r == true;
}

Widget _btn(bool isDark, String label, IconData icon, VoidCallback? onTap, {Color? color, bool outlined = false}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: SizedBox(
        height: 50,
        child: outlined
            ? OutlinedButton.icon(
                onPressed: onTap,
                icon: Icon(icon),
                label: Text(label, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: color ?? JphUi.primary(isDark),
                  side: BorderSide(color: (color ?? JphUi.primary(isDark)).withOpacity(0.5)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              )
            : ElevatedButton.icon(
                onPressed: onTap,
                icon: Icon(icon),
                label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: color ?? JphUi.primary(isDark), foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                ),
              ),
      ),
    );

/// a multi-line field in the same box as [JphUi.input]
Widget _area(bool isDark, String label, TextEditingController c, {String? hint}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(label, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: JphUi.sub(isDark))),
        TextField(
          controller: c,
          minLines: 3,
          maxLines: 8,
          maxLength: 3000,
          decoration: InputDecoration(hintText: txs(hint), border: InputBorder.none, counterText: '',
              hintStyle: TextStyle(color: JphUi.sub(isDark), fontSize: 13.5)),
          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: JphUi.text(isDark), height: 1.5),
        ),
      ]),
    );

/// % or amount (ج) for one person of the split
Widget _modeToggle(String mode, ValueChanged<String> on) => SegmentedButton<String>(
      showSelectedIcon: false,
      segments: const [ButtonSegment(value: 'fixed', label: Text('ج')), ButtonSegment(value: 'pct', label: Text('٪'))],
      selected: {mode},
      onSelectionChanged: (v) => on(v.first),
    );

class BrokeragePage extends StatefulWidget {
  final String kind; // resale | rental
  /// inside «المشاريع»'s bar (المشاريع / إعادة بيع / إيجار): no own background / header
  final bool embedded;
  /// inside «المشاريع»: its search box, sort (الأحدث / السعر / الاسم) and view (▦ / ☰) apply here too
  final String query;
  final int sort;
  final bool grid;
  /// the GM / the administrative officer: «إضافة عقار» is the header button (it bumps this); no floating button
  final ValueListenable<int>? addSignal;
  final bool headerAdd;
  const BrokeragePage({super.key, required this.kind, this.embedded = false, this.query = '', this.sort = 0, this.grid = false,
      this.addSignal, this.headerAdd = false});
  @override
  State<BrokeragePage> createState() => _BrokeragePageState();
}

class _BrokeragePageState extends State<BrokeragePage> {
  bool _loading = true, _installed = false, _listingsOn = false;
  Map<String, dynamic> _can = {};
  List<Map<String, dynamic>> _deals = [];
  List<Map<String, dynamic>> _listings = [];
  List<Map<String, dynamic>> _people = [];
  int _tab = 0; // المعروض · اتباع / اتأجر · الصفقات
  bool get _resale => widget.kind == 'resale';
  String get _title => _resale ? 'إعادة بيع' : 'إيجار';
  bool get _isDark => context.read<AppController>().isDark;

  @override
  void initState() {
    super.initState();
    widget.addSignal?.addListener(_onAdd);
    _load();
  }

  @override
  void didUpdateWidget(covariant BrokeragePage old) {
    super.didUpdateWidget(old);
    if (old.addSignal != widget.addSignal) {
      old.addSignal?.removeListener(_onAdd);
      widget.addSignal?.addListener(_onAdd);
    }
  }

  @override
  void dispose() {
    widget.addSignal?.removeListener(_onAdd);
    super.dispose();
  }

  void _onAdd() {
    if (!mounted || !_installed) return;
    _listingsOn ? _editListing(_isDark) : _propose(_isDark);
  }

  Future<void> _load() async {
    if (mounted) setState(() => _loading = true);
    final st = await _get('/brokerage/status');
    _installed = st['installed'] == true;
    _listingsOn = st['listings'] == true;
    _can = _map(st['can']);
    if (_installed) {
      final r = await Future.wait([
        _get('/brokerage/deals', {'kind': widget.kind}),
        if (_listingsOn) _get('/brokerage/listings', {'kind': widget.kind}),
      ]);
      _deals = _rows(r[0]['deals']);
      _listings = _listingsOn ? _rows(r[1]['listings']) : [];
      if (_people.isEmpty && (_can['propose'] == true || _can['approve'] == true)) _people = _rows((await _get('/brokerage/people'))['people']);
    }
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final fab = _installed && _can['propose'] == true && !widget.headerAdd
        ? FloatingActionButton.extended(
            backgroundColor: Glass.blue,
            foregroundColor: Colors.white,
            onPressed: () => _listingsOn ? _editListing(isDark) : _propose(isDark),
            icon: const Icon(Icons.add_home_work_rounded),
            label: Text(_listingsOn ? 'إضافة عقار' : 'صفقة جديدة'))
        : null;
    final Widget content = _loading
        ? const Center(child: CircularProgressIndicator())
        : !_installed
            ? _empty(isDark, '$_title هتشتغل بعد تحديث قاعدة البيانات (087) — مستنية موافقة المالك')
            : !_listingsOn
                ? _dealsView(isDark)
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                      child: Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: GlassSegments(
                          isDark: isDark,
                          big: false,
                          items: [
                            ('المعروض', _listings.where((l) => l['status'] == 'available' || l['status'] == 'pending').length),
                            (_resale ? 'اتباع' : 'اتأجر', _listings.where((l) => l['status'] == 'sold').length),
                            ('الصفقات', _deals.length),
                          ],
                          selected: _tab,
                          onTap: (i) => setState(() => _tab = i),
                        ),
                      ),
                    ),
                    Expanded(child: _tab == 2 ? _dealsView(isDark) : _listingsView(isDark)),
                  ]);
    if (widget.embedded) return Scaffold(backgroundColor: Colors.transparent, floatingActionButton: fab, body: content);
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          floatingActionButton: fab,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: _title),
              Expanded(child: content),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _empty(bool isDark, String t) => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(child: Text(t, textAlign: TextAlign.center, style: TextStyle(color: Glass.muted(isDark), fontSize: 14))),
      );

  /// cards in rows (▦) or one under the other (☰)
  Widget _cards(bool isDark, int count, Widget Function(int i) card, String none) => RefreshIndicator(
        onRefresh: _load,
        child: count == 0
            ? ListView(children: [_empty(isDark, none)])
            : widget.grid
                ? LayoutBuilder(builder: (context, c) {
                    final cols = math.max(1, (c.maxWidth / 330).floor());
                    return ListView(padding: const EdgeInsets.fromLTRB(12, 8, 12, 90), children: [
                      for (var i = 0; i < count; i += cols)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: IntrinsicHeight(
                            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                              for (var j = 0; j < cols; j++) ...[
                                if (j > 0) const SizedBox(width: 10),
                                Expanded(child: i + j < count ? card(i + j) : const SizedBox.shrink()),
                              ],
                            ]),
                          ),
                        ),
                    ]);
                  })
                : ListView.separated(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 90),
                    itemCount: count,
                    separatorBuilder: (_, __) => const SizedBox(height: 10),
                    itemBuilder: (_, i) => card(i),
                  ),
      );

  Widget _dealsView(bool isDark) {
    final shown = _shown;
    return _cards(isDark, shown.length, (i) => _card(isDark, shown[i]), _deals.isEmpty ? 'مفيش صفقات $_title لسه' : 'مفيش صفقة بالبحث ده');
  }

  Widget _listingsView(bool isDark) {
    final shown = _shownListings;
    final none = _tab == 0 ? 'مفيش عقارات معروضة لل$_title لسه — «إضافة عقار» تعرض أول واحد' : 'مفيش عقارات ${_resale ? 'اتباعت' : 'اتأجرت'} لسه';
    return _cards(isDark, shown.length, (i) => _listingCard(isDark, shown[i]), _listings.isEmpty || widget.query.trim().isEmpty ? none : 'مفيش عقار بالبحث ده');
  }

  /// the deals as the page's search / sort ask: الأحدث (as the server sends them) · السعر · الاسم
  List<Map<String, dynamic>> get _shown {
    final q = widget.query.trim();
    final list = _deals.where((d) => q.isEmpty || [d['property'], _map(d['owner'])['name'], _map(d['client'])['name']]
        .any((v) => '${v ?? ''}'.contains(q))).toList();
    if (widget.sort == 1) list.sort((a, b) => _n(b['price']).compareTo(_n(a['price'])));
    if (widget.sort == 2) list.sort((a, b) => '${a['property']}'.compareTo('${b['property']}'));
    return list;
  }

  /// the listings of this tab, searched (name / address / description) and sorted (الأحدث · السعر · الاسم)
  List<Map<String, dynamic>> get _shownListings {
    final q = widget.query.trim();
    final list = _listings.where((l) {
      final st = l['status'];
      final inTab = _tab == 0 ? (st == 'available' || st == 'pending') : st == 'sold';
      return inTab && (q.isEmpty || [l['title'], l['address'], l['description'], _map(l['listedBy'])['name']].any((v) => '${v ?? ''}'.contains(q)));
    }).toList();
    if (widget.sort == 1) list.sort((a, b) => _n(b['price']).compareTo(_n(a['price'])));
    if (widget.sort == 2) list.sort((a, b) => '${a['title']}'.compareTo('${b['title']}'));
    return list;
  }

  Widget _pill(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: c.withOpacity(0.16), borderRadius: BorderRadius.circular(99)),
        child: Text(t, style: TextStyle(fontSize: 11.5, color: c, fontWeight: FontWeight.w700)),
      );

  Widget _listingCard(bool isDark, Map<String, dynamic> l) {
    final photos = ((l['photos'] as List?) ?? const []).map((e) => '$e').toList();
    final (label, color) = _listingStatus(l['status'] as String?, _resale);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _openListing(isDark, l),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: Glass.tile(isDark, r: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(fit: StackFit.expand, children: [
              photos.isEmpty
                  ? Container(
                      color: Glass.blue.withOpacity(0.08),
                      child: Icon(_resale ? Icons.home_work_rounded : Icons.key_rounded, size: 46, color: Glass.blue.withOpacity(0.55)))
                  : _ListingPhoto(listing: '${l['id']}', id: photos.first),
              PositionedDirectional(top: 10, start: 10, child: _pill(label, color)),
              if (photos.length > 1)
                PositionedDirectional(
                  bottom: 10,
                  end: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(99)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.photo_library_rounded, size: 14, color: Colors.white),
                      const SizedBox(width: 4),
                      Text('${photos.length}', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700)),
                    ]),
                  ),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                    child: Text('${l['title']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Glass.ink(isDark)))),
                _pill(finishingAr(l['finishing'] as String?), Glass.muted(isDark)),
              ]),
              const SizedBox(height: 6),
              Row(children: [
                Icon(Icons.location_on_rounded, size: 15, color: Glass.muted(isDark)),
                const SizedBox(width: 4),
                Expanded(
                    child: Text('${l['address']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12.5, color: Glass.muted(isDark)))),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                Icon(Icons.square_foot_rounded, size: 16, color: Glass.muted(isDark)),
                const SizedBox(width: 3),
                Text('${_fmt(_n(l['area']))} م²', style: TextStyle(fontSize: 13, color: Glass.ink(isDark))),
                const Spacer(),
                Text(_resale ? _egp(l['price']) : '${_egp(l['price'])} / شهر',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: JphUi.primary(isDark))),
              ]),
              const SizedBox(height: 6),
              Text('عرضه: ${_map(l['listedBy'])['name'] ?? '—'}', style: TextStyle(fontSize: 11.5, color: Glass.muted(isDark))),
            ]),
          ),
        ]),
      ),
    );
  }

  // ----------------------------------------------------------------- «إضافة عقار» / «تعديل» — the listing form
  Future<void> _editListing(bool isDark, [Map<String, dynamic>? l]) async {
    final title = TextEditingController(text: '${l?['title'] ?? ''}'), address = TextEditingController(text: '${l?['address'] ?? ''}');
    final area = TextEditingController(text: l == null ? '' : _fmt(_n(l['area'])).replaceAll(',', ''));
    final price = TextEditingController(text: l == null ? '' : _fmt(_n(l['price'])).replaceAll(',', ''));
    final desc = TextEditingController(text: '${l?['description'] ?? ''}');
    final owner = _map(l?['owner']);
    final ownerName = TextEditingController(text: '${owner['name'] ?? ''}'), ownerPhone = TextEditingController(text: '${owner['phone'] ?? ''}');
    String? finishing = l?['finishing'] as String?;
    final kept = ((l?['photos'] as List?) ?? const []).map((e) => '$e').toList();
    final removed = <String>{};
    final added = <_Picked>[];
    final ref = uuidV4();
    final lid = l == null ? null : '${l['id']}';

    await _form(context, isDark, l == null ? 'عرض عقار لل$_title' : 'تعديل العقار', (set) => [
          // photos: what is there, what is added, and «إضافة صور»
          SizedBox(
            height: 92,
            child: ListView(scrollDirection: Axis.horizontal, children: [
              InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () async {
                  final room = 8 - (kept.length - removed.length) - added.length;
                  final got = await _pickPhotos(context, room);
                  if (got.isNotEmpty) set(() => added.addAll(got));
                },
                child: Container(
                  width: 92,
                  decoration: JphUi.box(isDark),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Icon(Icons.add_photo_alternate_rounded, color: Ar.accent, size: 28),
                    const SizedBox(height: 4),
                    Text('صور العقار', style: TextStyle(fontSize: 11.5, color: JphUi.sub(isDark), fontWeight: FontWeight.w600)),
                  ]),
                ),
              ),
              for (final id in kept.where((x) => !removed.contains(x)))
                _thumb(Positioned.fill(child: _ListingPhoto(listing: lid!, id: id)), () => set(() => removed.add(id))),
              for (final p in added) _thumb(Positioned.fill(child: Image.memory(p.$3, fit: BoxFit.cover)), () => set(() => added.remove(p))),
            ]),
          ),
          JphUi.input(isDark: isDark, label: 'اسم العقار أو نوعه *', hint: 'شقة، محل، فيلا…', controller: title, icon: Icons.home_work_rounded, big: false),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final t in _types)
              ChoiceChip(label: Text(t), selected: title.text.trim() == t, onSelected: (_) => set(() => title.text = t)),
          ]),
          JphUi.input(isDark: isDark, label: 'عنوان العقار *', controller: address, icon: Icons.location_on_rounded, big: false),
          Row(children: [
            Expanded(child: JphUi.input(isDark: isDark, label: 'المساحة *', controller: area, number: true, suffix: 'م²', icon: Icons.square_foot_rounded, big: false)),
            const SizedBox(width: 10),
            Expanded(
                child: JphUi.input(isDark: isDark, label: _resale ? 'السعر *' : 'الإيجار الشهري *', controller: price, number: true, suffix: 'ج',
                    icon: Icons.payments_rounded, big: false)),
          ]),
          JphUi.picker(
            isDark: isDark,
            icon: Icons.format_paint_rounded,
            iconColor: Ar.green,
            label: 'التشطيب *',
            value: finishing == null ? 'اختار التشطيب' : finishingAr(finishing),
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, 'التشطيب', [for (final f in finishingOptions) (f.$1, f.$2, Icons.format_paint_rounded)],
                  selected: finishing);
              if (v != null) set(() => finishing = v);
            },
          ),
          _area(isDark, 'الوصف', desc, hint: 'الدور، الواجهة، عدد الغرف، المميزات…'),
          Text('بيانات المالك (اختياري — بتظهر للإدارة واللي عارض العقار بس)', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
          JphUi.input(isDark: isDark, label: 'اسم المالك', controller: ownerName, icon: Icons.person_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'تليفون المالك', controller: ownerPhone, icon: Icons.phone_rounded, big: false),
        ], () async {
      if (title.text.trim().length < 2 || address.text.trim().length < 2 || (_num(area) ?? 0) <= 0 || (_num(price) ?? 0) <= 0 || finishing == null) {
        JphUi.toast(context, {'success': false, 'message': 'كمّل البيانات المطلوبة (*)'});
        return false;
      }
      final body = {
        'title': title.text.trim(), 'address': address.text.trim(), 'area': _num(area), 'price': _num(price), 'finishing': finishing,
        'description': desc.text.trim(), 'ownerName': ownerName.text.trim(), 'ownerPhone': ownerPhone.text.trim(),
      };
      final r = l == null
          ? await _send('/brokerage/listings', {'kind': widget.kind, 'clientRef': ref, ...body})
          : await _send('/brokerage/listings/$lid', body, patch: true);
      if (r['success'] != true) {
        if (mounted) JphUi.toast(context, r);
        return false;
      }
      final id = l == null ? '${_map(r['listing'])['id']}' : lid!;
      var failed = 0;
      for (final x in removed) {
        if ((await _send('/brokerage/listings/$id/photos/$x/remove', {}))['success'] != true) failed++;
      }
      for (final p in added) {
        if ((await _send('/brokerage/listings/$id/photos', {'mime': p.$1, 'image': p.$2}))['success'] != true) failed++;
      }
      if (mounted) {
        JphUi.toast(context, {
          'success': failed == 0,
          'message': failed == 0 ? (l == null ? 'العقار اتعرض ✅' : 'اتحفظ ✅') : 'العقار اتحفظ بس $failed صورة متحفظتش — جرّب تاني من «تعديل»',
        });
      }
      return true;
    }, saveLabel: l == null ? 'اعرض العقار' : 'حفظ');
    _load();
  }

  Widget _thumb(Widget image, VoidCallback onRemove) => Padding(
        padding: const EdgeInsetsDirectional.only(start: 8),
        child: SizedBox(
          width: 92,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(children: [
              image,
              PositionedDirectional(
                top: 4,
                end: 4,
                child: GestureDetector(
                  onTap: onRemove,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: const BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                    child: const Icon(Icons.close_rounded, size: 16, color: Colors.white),
                  ),
                ),
              ),
            ]),
          ),
        ),
      );

  // ----------------------------------------------------------------- one listing: photos, details, sell, edit, withdraw
  Future<void> _openListing(bool isDark, Map<String, dynamic> l) async {
    final photos = ((l['photos'] as List?) ?? const []).map((e) => '$e').toList();
    final can = _map(l['can']);
    final (label, color) = _listingStatus(l['status'] as String?, _resale);
    final dealRef = _map(l['deal']);
    final deal = _deals.firstWhere((d) => d['id'] == dealRef['id'], orElse: () => <String, dynamic>{});
    final owner = _map(l['owner']);
    var page = 0;
    String? action;
    await showAppSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, set) => Container(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.92),
            margin: const EdgeInsets.all(12),
            decoration: Glass.sheet(isDark, r: 24),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                AspectRatio(
                  aspectRatio: 16 / 10,
                  child: Stack(fit: StackFit.expand, children: [
                    photos.isEmpty
                        ? Container(
                            color: Glass.blue.withOpacity(0.08),
                            child: Icon(_resale ? Icons.home_work_rounded : Icons.key_rounded, size: 60, color: Glass.blue.withOpacity(0.55)))
                        : PageView(
                            onPageChanged: (i) => set(() => page = i),
                            children: [for (final p in photos) _ListingPhoto(listing: '${l['id']}', id: p, fit: BoxFit.cover)],
                          ),
                    PositionedDirectional(
                      top: 8,
                      end: 8,
                      child: IconButton.filled(
                        style: IconButton.styleFrom(backgroundColor: Colors.black45),
                        onPressed: () => Navigator.pop(ctx),
                        icon: const Icon(Icons.close_rounded, color: Colors.white),
                      ),
                    ),
                    PositionedDirectional(top: 14, start: 14, child: _pill(label, color)),
                    if (photos.length > 1)
                      Positioned(
                        bottom: 10,
                        left: 0,
                        right: 0,
                        child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                          for (var i = 0; i < photos.length; i++)
                            Container(
                              width: i == page ? 18 : 7,
                              height: 7,
                              margin: const EdgeInsets.symmetric(horizontal: 2),
                              decoration: BoxDecoration(color: i == page ? Colors.white : Colors.white54, borderRadius: BorderRadius.circular(99)),
                            ),
                        ]),
                      ),
                  ]),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Row(children: [
                      Expanded(child: Text('${l['title']}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                      Text(_resale ? _egp(l['price']) : '${_egp(l['price'])} / شهر',
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.primary(isDark))),
                    ]),
                    const SizedBox(height: 12),
                    JphUi.statGrid([
                      JphUi.stat(isDark, 'المساحة', '${_fmt(_n(l['area']))} م²', Icons.square_foot_rounded, Ar.accent),
                      JphUi.stat(isDark, 'التشطيب', finishingAr(l['finishing'] as String?), Icons.format_paint_rounded, Ar.green),
                    ]),
                    const SizedBox(height: 10),
                    JphUi.readOnly(isDark: isDark, label: 'العنوان', value: '${l['address']}', icon: Icons.location_on_rounded),
                    if ('${l['description'] ?? ''}'.trim().isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: JphUi.box(isDark),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('الوصف', style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: JphUi.sub(isDark))),
                          const SizedBox(height: 6),
                          Text('${l['description']}', style: TextStyle(fontSize: 14, height: 1.6, color: JphUi.text(isDark))),
                        ]),
                      ),
                    ],
                    if ('${owner['name'] ?? ''}'.isNotEmpty || '${owner['phone'] ?? ''}'.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      JphUi.readOnly(isDark: isDark, label: 'المالك', value: [owner['name'], owner['phone']].where((v) => '${v ?? ''}'.isNotEmpty).join(' · '),
                          icon: Icons.person_rounded),
                    ],
                    const SizedBox(height: 10),
                    Text('عرضه ${_map(l['listedBy'])['name'] ?? '—'}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                    if (deal.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      _dealSummary(isDark, deal),
                    ],
                    const SizedBox(height: 14),
                    if (can['sell'] == true)
                      _btn(isDark, _resale ? 'بيع العقار' : 'تأجير العقار', Icons.handshake_rounded, () => Navigator.pop(ctx, action = 'sell')),
                    if (deal['canReceive'] == true)
                      _btn(isDark, 'استلام العمولة وتقسيمها', Icons.call_split_rounded, () => Navigator.pop(ctx, action = 'receive'), color: Colors.green.shade700),
                    if (deal.isNotEmpty)
                      _btn(isDark, 'تفاصيل الصفقة', Icons.receipt_long_rounded, () => Navigator.pop(ctx, action = 'deal'), outlined: true),
                    _btn(isDark, 'عرض سعر', Icons.request_quote_rounded, () => Navigator.pop(ctx, action = 'quote'), outlined: true),
                    if (can['edit'] == true)
                      _btn(isDark, 'تعديل', Icons.edit_rounded, () => Navigator.pop(ctx, action = 'edit'), outlined: true),
                    if (can['withdraw'] == true)
                      _btn(isDark, 'شيل من العرض', Icons.visibility_off_rounded, () => Navigator.pop(ctx, action = 'withdraw'), outlined: true, color: Colors.red),
                  ]),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'sell':
        await _sell(isDark, l);
      case 'receive':
        await _receive(isDark, deal);
      case 'deal':
        await _open(isDark, deal);
      case 'quote':
        await printListingQuote(context, isDark, l);
      case 'edit':
        await _editListing(isDark, l);
      case 'withdraw':
        final r = await _send('/brokerage/listings/${l['id']}/withdraw', {}, ok: 'اتشال من العرض');
        if (mounted) JphUi.toast(context, r);
        _load();
    }
  }

  Widget _dealSummary(bool isDark, Map<String, dynamic> d) {
    final (label, color) = _status(d['status'] as String?);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: JphUi.box(isDark),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(_resale ? 'البيع' : 'الإيجار', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
          _pill(label, color),
        ]),
        const SizedBox(height: 8),
        _line(isDark, _resale ? 'المشتري' : 'المستأجر', '${_map(d['client'])['name']}${'${_map(d['client'])['phone'] ?? ''}'.isEmpty ? '' : ' · ${_map(d['client'])['phone']}'}'),
        _line(isDark, 'السعر النهائي', _egp(d['price'])),
        _line(isDark, 'العمولة', _egp(_map(d['commission'])['total'])),
        _line(isDark, 'البائع', '${_map(d['closer'])['name']}'),
      ]),
    );
  }

  // ----------------------------------------------------------------- «بيع» / «تأجير» a listing
  Future<void> _sell(bool isDark, Map<String, dynamic> l) async {
    final client = TextEditingController(), phone = TextEditingController();
    final price = TextEditingController(text: _fmt(_n(l['price'])).replaceAll(',', ''));
    final commission = TextEditingController(), notes = TextEditingController();
    final ref = uuidV4();
    final ok = await _form(context, isDark, '${_resale ? 'بيع' : 'تأجير'} — ${l['title']}', (set) => [
          JphUi.input(isDark: isDark, label: _resale ? 'اسم المشتري *' : 'اسم المستأجر *', controller: client, icon: Icons.person_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'تليفون العميل', controller: phone, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'سعر البيع النهائي *' : 'الإيجار الشهري النهائي *', controller: price, number: true, suffix: 'ج',
              icon: Icons.payments_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'العمولة اللي اتاخدت *', controller: commission, number: true, suffix: 'ج', icon: Icons.savings_rounded,
              big: false),
          _area(isDark, 'ملاحظات', notes),
          Text('هيوصل إشعار للمسؤول الإداري يستلم العمولة ويحدد التقسيمة.', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
        ], () async {
      if (client.text.trim().length < 2 || (_num(price) ?? 0) <= 0 || (_num(commission) ?? 0) <= 0) {
        JphUi.toast(context, {'success': false, 'message': 'كمّل البيانات المطلوبة (*)'});
        return false;
      }
      final r = await _send('/brokerage/listings/${l['id']}/sell', {
        'clientName': client.text.trim(), 'clientPhone': phone.text.trim(), 'finalPrice': _num(price), 'commission': _num(commission),
        'notes': notes.text.trim(), 'clientRef': ref,
      }, ok: 'اتسجل ✅ — اتبعت للمسؤول الإداري');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: _resale ? 'تسجيل البيع' : 'تسجيل الإيجار', saveIcon: Icons.handshake_rounded);
    if (ok) setState(() => _tab = 0);
    _load();
  }

  // ----------------------------------------------------------------- the administrative officer: receive + split
  Future<void> _receive(bool isDark, Map<String, dynamic> d) async {
    final amount = TextEditingController(text: _fmt(_n(_map(d['commission'])['total'])).replaceAll(',', ''));
    final closer = _map(d['closer']), lister = _map(d['contributor']);
    final sameLister = closer['id'] == lister['id'];
    final seller = TextEditingController(), list = TextEditingController(), mgr = TextEditingController();
    var sellerMode = 'fixed', listMode = 'fixed', mgrMode = 'fixed';
    String? manager = _map(d['salesManager'])['id'] as String?;
    var method = 'cash';
    final ref = uuidV4();
    final recipient = ApiService.can('cash.office') ? 'manager' : 'hr';
    num total() => _num(amount) ?? 0;
    num part(TextEditingController c, String mode) => mode == 'pct' ? total() * (_num(c) ?? 0) / 100 : (_num(c) ?? 0);
    num given() => part(seller, sellerMode) + (sameLister ? 0 : part(list, listMode)) + (manager == null ? 0 : part(mgr, mgrMode));
    Widget person(StateSetter set, String who, String name, TextEditingController c, String mode, ValueChanged<String> on) => Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: JphUi.box(isDark),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Expanded(
                child: Text.rich(TextSpan(children: [
                  TextSpan(text: '$who  ', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark), fontWeight: FontWeight.w600)),
                  TextSpan(text: name, style: TextStyle(fontSize: 14.5, color: JphUi.text(isDark), fontWeight: FontWeight.w800)),
                ])),
              ),
              _modeToggle(mode, (v) => set(() => on(v))),
            ]),
            TextField(
              controller: c,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              onChanged: (_) => set(() {}),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: mode == 'pct' ? 'النسبة' : 'المبلغ',
                suffixText: mode == 'pct' ? '٪ = ${_egp(part(c, mode))}' : 'ج',
              ),
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: JphUi.text(isDark)),
            ),
          ]),
        );
    await _form(context, isDark, 'استلام العمولة وتقسيمها', (set) {
      final office = total() - given();
      return [
        _dealSummary(isDark, d),
        JphUi.input(isDark: isDark, label: 'مبلغ العمولة المستلم', controller: amount, number: true, suffix: 'ج', icon: Icons.savings_rounded,
            onChanged: (_) => set(() {})),
        JphUi.picker(
          isDark: isDark,
          icon: method == 'cash' ? Icons.payments_rounded : Icons.account_balance_rounded,
          iconColor: method == 'cash' ? Ar.green : Ar.accent,
          label: 'الفلوس دخلت',
          value: method == 'cash' ? 'نقدي' : 'بنك (تحويل)',
          onTap: () async {
            final v = await JphUi.sheet<String>(context, isDark, 'الفلوس دخلت', [
              ('cash', 'نقدي', Icons.payments_rounded),
              ('bank_transfer', 'بنك (تحويل)', Icons.account_balance_rounded),
            ], selected: method);
            if (v != null) set(() => method = v);
          },
        ),
        Text('التقسيمة', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
        person(set, sameLister ? 'البائع وصاحب العرض' : 'البائع', '${closer['name']}', seller, sellerMode, (v) => sellerMode = v),
        if (!sameLister) person(set, 'صاحب العرض', '${lister['name']}', list, listMode, (v) => listMode = v),
        JphUi.picker(
          isDark: isDark,
          icon: Icons.supervisor_account_rounded,
          iconColor: Ar.accent,
          label: 'مدير المبيعات',
          value: manager == null ? 'من غير' : '${_people.firstWhere((p) => p['id'] == manager, orElse: () => {'name': '—'})['name']}',
          onTap: () async {
            final v = await JphUi.sheet<String>(context, isDark, 'مدير المبيعات', [
              ('', 'من غير', Icons.block_rounded),
              for (final p in _people)
                if (p['id'] != closer['id'] && p['id'] != lister['id']) ('${p['id']}', '${p['name']}', Icons.badge_rounded),
            ], selected: manager ?? '', people: true);
            if (v != null) set(() => manager = v.isEmpty ? null : v);
          },
        ),
        if (manager != null) person(set, 'مدير المبيعات', '${_people.firstWhere((p) => p['id'] == manager, orElse: () => {'name': ''})['name']}', mgr, mgrMode, (v) => mgrMode = v),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: (office < -0.005 ? Colors.red : Colors.green).withOpacity(0.12),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Row(children: [
            Icon(Icons.business_rounded, color: office < -0.005 ? Colors.red : Colors.green.shade700),
            const SizedBox(width: 10),
            Expanded(
                child: Text(office < -0.005 ? 'التقسيمة أكبر من العمولة بـ ${_egp(-office)}' : 'الباقي للمكتب',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: JphUi.text(isDark)))),
            if (office >= -0.005)
              Text(_egp(office), style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.green.shade700)),
          ]),
        ),
      ];
    }, () async {
      if (total() <= 0) {
        JphUi.toast(context, {'success': false, 'message': 'اكتب مبلغ العمولة'});
        return false;
      }
      if (total() - given() < -0.005) {
        JphUi.toast(context, {'success': false, 'message': 'التقسيمة أكبر من العمولة'});
        return false;
      }
      Map<String, dynamic>? share(String role, dynamic id, TextEditingController c, String mode) =>
          (_num(c) ?? 0) > 0 ? {'role': role, 'employeeId': id, 'mode': mode, 'value': _num(c)} : null;
      final shares = [
        share('closer', closer['id'], seller, sellerMode),
        if (!sameLister) share('contributor', lister['id'], list, listMode),
        if (manager != null) share('sales_manager', manager, mgr, mgrMode),
      ].whereType<Map<String, dynamic>>().toList();
      if (shares.isEmpty) {
        JphUi.toast(context, {'success': false, 'message': 'حدد نصيب واحد على الأقل (الباقي للمكتب)'});
        return false;
      }
      final r = await _send('/brokerage/deals/${d['id']}/receive', {
        'amount': total(), 'salesManagerId': manager, 'shares': shares, 'recipient': recipient, 'paymentMethod': method, 'clientRef': ref,
      }, ok: 'العمولة اتستلمت واتقسمت ✅');
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    }, saveLabel: 'استلام وتقسيم', saveIcon: Icons.call_split_rounded);
    _load();
  }

  // ----------------------------------------------------------------- deals (087): the card, a manual deal
  Widget _card(bool isDark, Map<String, dynamic> d) {
    final cm = _map(d['commission']);
    final (label, color) = _status(d['status'] as String?);
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _open(isDark, d),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: Glass.tile(isDark, r: 18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('${d['property']}', style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: Glass.ink(isDark)))),
            _pill(label, color),
          ]),
          const SizedBox(height: 6),
          Text('${_map(d['owner'])['name']} ← ${_map(d['client'])['name']} · ${_resale ? 'السعر' : 'الإيجار'} ${_egp(d['price'])}',
              style: TextStyle(fontSize: 12.5, color: Glass.muted(isDark))),
          const SizedBox(height: 6),
          Text('العمولة ${_egp(cm['total'])} · اتحصل ${_egp(cm['collected'])} · باقي ${_egp(cm['receivable'])}',
              style: TextStyle(fontSize: 13, color: Glass.ink(isDark))),
          if (d['canReceive'] == true) ...[
            const SizedBox(height: 8),
            _pill('مستنية استلام العمولة منك', Colors.green.shade700),
          ],
        ]),
      ),
    );
  }

  // ----------------------------------------------------------------- a new deal (the sales employee's proposal)
  Future<void> _propose(bool isDark) async {
    final property = TextEditingController(), owner = TextEditingController(), ownerPhone = TextEditingController();
    final client = TextEditingController(), clientPhone = TextEditingController(), price = TextEditingController();
    final rate = TextEditingController(text: '2'), ownerAmount = TextEditingController(), clientAmount = TextEditingController();
    final notes = TextEditingController();
    String paidBy = 'both', arrangement = 'owner_month';
    String? closer, manager;
    await showAppSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        Widget pick(String title, String? value, ValueChanged<String?> on) => ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(title, style: TextStyle(color: Glass.muted(isDark), fontSize: 12.5)),
              subtitle: Text(value == null ? 'أنا' : '${_people.firstWhere((p) => p['id'] == value, orElse: () => {'name': '—'})['name']}',
                  style: TextStyle(color: Glass.ink(isDark), fontSize: 14.5)),
              trailing: const Icon(Icons.expand_more_rounded),
              onTap: () async {
                final v = await JphUi.sheet<String?>(ctx, isDark, title, [
                  (null, 'أنا', Icons.person_rounded),
                  for (final p in _people) (p['id'] as String, '${p['name']}', Icons.badge_rounded),
                ]);
                set(() => on(v));
              },
            );
        return _sheet(isDark, ctx, 'صفقة $_title جديدة', [
          JphUi.input(isDark: isDark, label: _resale ? 'العقار (الوصف والعنوان) *' : 'الوحدة المؤجرة *', controller: property, icon: Icons.home_work_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'المالك (البائع) *' : 'المالك (المؤجر) *', controller: owner, icon: Icons.person_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'تليفون المالك', controller: ownerPhone, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'المشتري *' : 'المستأجر *', controller: client, icon: Icons.person_outline_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'تليفون المشتري' : 'تليفون المستأجر', controller: clientPhone, icon: Icons.phone_rounded, big: false),
          JphUi.input(isDark: isDark, label: _resale ? 'سعر البيع *' : 'الإيجار الشهري *', controller: price, number: true, icon: Icons.payments_rounded, big: false),
          if (_resale) ...[
            JphUi.input(isDark: isDark, label: 'نسبة العمولة ٪ (من 1 لـ 2.5)', controller: rate, number: true, icon: Icons.percent_rounded, big: false),
            _choice(isDark, 'مين بيدفع العمولة', paidBy, const [('owner', 'البائع'), ('client', 'المشتري'), ('both', 'الاتنين')], (v) => set(() => paidBy = v)),
            if (paidBy == 'both') JphUi.input(isDark: isDark, label: 'نصيب البائع من العمولة (والباقي على المشتري)', controller: ownerAmount, number: true, icon: Icons.call_split_rounded, big: false),
          ] else ...[
            _choice(isDark, 'العمولة', arrangement, _arrangements, (v) => set(() => arrangement = v)),
            if (arrangement == 'fixed') ...[
              JphUi.input(isDark: isDark, label: 'على المالك', controller: ownerAmount, number: true, icon: Icons.person_rounded, big: false),
              JphUi.input(isDark: isDark, label: 'على المستأجر', controller: clientAmount, number: true, icon: Icons.person_outline_rounded, big: false),
            ],
          ],
          pick('اللي قفل الصفقة', closer, (v) => closer = v),
          pick('مدير المبيعات (اختياري)', manager, (v) => manager = v),
          JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded, big: false),
        ], 'إرسال للاعتماد', () async {
          final r = await _send('/brokerage/deals', {
            'kind': widget.kind, 'property': property.text.trim(), 'ownerName': owner.text.trim(), 'ownerPhone': ownerPhone.text.trim(),
            'clientName': client.text.trim(), 'clientPhone': clientPhone.text.trim(), 'price': num.tryParse(price.text.trim()),
            if (_resale) ...{'ratePct': num.tryParse(rate.text.trim()), 'paidBy': paidBy, if (paidBy == 'both') 'ownerAmount': num.tryParse(ownerAmount.text.trim()) ?? 0},
            if (!_resale) ...{'arrangement': arrangement, if (arrangement == 'fixed') ...{'ownerAmount': num.tryParse(ownerAmount.text.trim()) ?? 0, 'clientAmount': num.tryParse(clientAmount.text.trim()) ?? 0}},
            if (closer != null) 'closerId': closer, if (manager != null) 'salesManagerId': manager, 'notes': notes.text.trim(),
          }, ok: 'اتبعتت للمدير ✅');
          if (!ctx.mounted) return;
          JphUi.toast(ctx, r);
          if (r['success'] == true) Navigator.pop(ctx);
        });
      }),
    );
    _load();
  }

  Widget _choice(bool isDark, String title, String value, List<(String, String)> items, ValueChanged<String> on) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: TextStyle(color: Glass.muted(isDark), fontSize: 12.5)),
          const SizedBox(height: 6),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final (k, l) in items) ChoiceChip(label: Text(l), selected: value == k, onSelected: (_) => on(k)),
          ]),
        ]),
      );

  Widget _sheet(bool isDark, BuildContext ctx, String title, List<Widget> children, String action, Future<void> Function() onAction) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.9, maxWidth: 640),
          margin: const EdgeInsets.all(12),
          decoration: Glass.sheet(isDark, r: 24),
          child: Directionality(
            textDirection: ui.TextDirection.rtl,
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.all(16), children: [
              Row(children: [
                Expanded(child: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                IconButton(onPressed: () => Navigator.pop(ctx), icon: Icon(Icons.close_rounded, color: JphUi.sub(isDark))),
              ]),
              const SizedBox(height: 8),
              for (final w in children) Padding(padding: const EdgeInsets.only(bottom: 8), child: w),
              const SizedBox(height: 8),
              _btn(isDark, action, Icons.check_rounded, onAction),
            ]),
          ),
        ),
      );

  // ----------------------------------------------------------------- one deal: details, approval, collection, cancel
  Future<void> _open(bool isDark, Map<String, dynamic> d) async {
    final cm = _map(d['commission']);
    final o = _map(cm['owner']), c = _map(cm['client']);
    final shares = _rows(d['shares']);
    const roleAr = {'contributor': 'جايب العقار', 'closer': 'اللي قفل الصفقة', 'sales_manager': 'مدير المبيعات', 'other': 'مستفيد آخر'};
    await showAppSheet(
      context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _sheet(isDark, ctx, '${d['property']}', [
        _line(isDark, 'الحالة', _status(d['status'] as String?).$1),
        _line(isDark, _resale ? 'سعر البيع' : 'الإيجار الشهري', _egp(d['price'])),
        if (d['ratePct'] != null) _line(isDark, 'النسبة', '${d['ratePct']}٪'),
        _line(isDark, 'جايب العقار', '${_map(d['contributor'])['name']}'),
        _line(isDark, 'اللي قفل الصفقة', '${_map(d['closer'])['name']}'),
        if (d['salesManager'] != null) _line(isDark, 'مدير المبيعات', '${_map(d['salesManager'])['name']}'),
        const Divider(),
        _line(isDark, 'عمولة المالك', '${_egp(o['due'])} — اتحصل ${_egp(o['collected'])} · باقي ${_egp(o['receivable'])}'),
        _line(isDark, _resale ? 'عمولة المشتري' : 'عمولة المستأجر', '${_egp(c['due'])} — اتحصل ${_egp(c['collected'])} · باقي ${_egp(c['receivable'])}'),
        _line(isDark, 'الإجمالي', '${_egp(cm['total'])} — باقي ${_egp(cm['receivable'])}'),
        if (shares.isNotEmpty) ...[
          const Divider(),
          for (final s in shares) ...[
            _line(isDark, roleAr[s['role']] ?? '${s['role']}',
                '${_map(s['employee'])['name'] ?? s['beneficiary']} — ${_egp(s['amount'])}${s['mode'] == 'pct' ? ' (${s['value']}٪)' : ''}'
                '${s['settlement'] != null ? ' · اتصرف (إيصال ${_map(s['settlement'])['refNo']})' : ''}'),
            // an approved beneficiary outside the staff: paid once from the office cashbox, after the commission is all in
            if (s['canSettle'] == true)
              OutlinedButton.icon(
                onPressed: () async {
                  final r = await _send('/brokerage/deals/${d['id']}/shares/${s['id']}/settle', {'clientRef': _uuidFrom('')}, ok: 'اتصرف ✅');
                  if (!ctx.mounted) return;
                  JphUi.toast(ctx, r);
                  if (r['success'] == true) Navigator.pop(ctx);
                },
                icon: const Icon(Icons.outbound_rounded),
                label: Text('صرف نصيب ${s['beneficiary']} من الخزنة')),
          ],
        ],
        if (d['canApprove'] == true) ...[
          const Divider(),
          OutlinedButton.icon(onPressed: () => _approve(isDark, ctx, d), icon: const Icon(Icons.verified_rounded), label: const Text('اعتماد وتوزيع العمولة')),
          OutlinedButton.icon(
              onPressed: () async {
                final r = await _send('/brokerage/deals/${d['id']}/decision', {'decision': 'reject'}, ok: 'اترفضت');
                if (!ctx.mounted) return;
                JphUi.toast(ctx, r);
                if (r['success'] == true) Navigator.pop(ctx);
              },
              icon: const Icon(Icons.close_rounded), label: const Text('رفض')),
        ],
        if (d['canReceive'] == true) ...[
          const Divider(),
          OutlinedButton.icon(
              onPressed: () {
                Navigator.pop(ctx);
                _receive(isDark, d);
              },
              icon: const Icon(Icons.call_split_rounded),
              label: const Text('استلام العمولة وتقسيمها')),
        ],
        if (d['canCollect'] == true) ...[
          const Divider(),
          if (_n(o['receivable']) > 0) OutlinedButton.icon(onPressed: () => _collect(isDark, ctx, d, 'owner', o['receivable']), icon: const Icon(Icons.payments_rounded), label: const Text('تحصيل من المالك')),
          if (_n(c['receivable']) > 0) OutlinedButton.icon(onPressed: () => _collect(isDark, ctx, d, 'client', c['receivable']), icon: const Icon(Icons.payments_rounded), label: Text(_resale ? 'تحصيل من المشتري' : 'تحصيل من المستأجر')),
        ],
      ], 'إغلاق', () async => Navigator.pop(ctx)),
    );
    _load();
  }

  Widget _line(bool isDark, String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 120, child: Text(k, style: TextStyle(color: Glass.muted(isDark), fontSize: 12.5))),
          Expanded(child: Text(v, style: TextStyle(color: Glass.ink(isDark), fontSize: 13.5))),
        ]),
      );

  Future<void> _approve(bool isDark, BuildContext parent, Map<String, dynamic> d) async {
    final total = _n(_map(d['commission'])['total']);
    final rows = <(String, String, String?, TextEditingController, String)>[
      ('contributor', 'جايب العقار — ${_map(d['contributor'])['name']}', _map(d['contributor'])['id'] as String?, TextEditingController(), 'pct'),
      if (_map(d['closer'])['id'] != _map(d['contributor'])['id'])
        ('closer', 'اللي قفل — ${_map(d['closer'])['name']}', _map(d['closer'])['id'] as String?, TextEditingController(), 'pct'),
      if (d['salesManager'] != null)
        ('sales_manager', 'مدير المبيعات — ${_map(d['salesManager'])['name']}', _map(d['salesManager'])['id'] as String?, TextEditingController(), 'pct'),
    ];
    final modes = {for (final r in rows) r.$1: 'pct'};
    final otherName = TextEditingController(), otherAmount = TextEditingController();
    await showAppSheet(
      context: parent, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        num sum() {
          var s = 0.0;
          for (final r in rows) {
            final v = num.tryParse(r.$4.text.trim()) ?? 0;
            s += modes[r.$1] == 'pct' ? total * v / 100 : v;
          }
          return s + (num.tryParse(otherAmount.text.trim()) ?? 0);
        }

        return _sheet(isDark, ctx, 'توزيع عمولة ${_egp(total)}', [
          for (final r in rows) ...[
            Text(r.$2, style: TextStyle(color: Glass.ink(isDark), fontSize: 13.5)),
            Row(children: [
              Expanded(child: JphUi.input(isDark: isDark, label: modes[r.$1] == 'pct' ? 'النسبة ٪' : 'المبلغ', controller: r.$4, number: true, big: false, onChanged: (_) => set(() {}))),
              const SizedBox(width: 8),
              SegmentedButton<String>(
                segments: const [ButtonSegment(value: 'pct', label: Text('٪')), ButtonSegment(value: 'fixed', label: Text('ج'))],
                selected: {modes[r.$1]!},
                onSelectionChanged: (v) => set(() => modes[r.$1] = v.first),
              ),
            ]),
          ],
          JphUi.input(isDark: isDark, label: 'مستفيد آخر (اختياري)', controller: otherName, icon: Icons.person_add_alt_rounded, big: false),
          JphUi.input(isDark: isDark, label: 'مبلغه', controller: otherAmount, number: true, big: false, onChanged: (_) => set(() {})),
          Text('الموزع ${_egp(sum())} · للمكتب ${_egp(math.max(0, total - sum()))}',
              style: TextStyle(color: sum() > total + 0.005 ? Colors.red : Glass.muted(isDark), fontSize: 13)),
        ], 'اعتماد', () async {
          final shares = [
            for (final r in rows)
              if ((num.tryParse(r.$4.text.trim()) ?? 0) > 0) {'role': r.$1, 'employeeId': r.$3, 'mode': modes[r.$1], 'value': num.tryParse(r.$4.text.trim())},
            if (otherName.text.trim().length >= 2 && (num.tryParse(otherAmount.text.trim()) ?? 0) > 0)
              {'role': 'other', 'beneficiary': otherName.text.trim(), 'mode': 'fixed', 'value': num.tryParse(otherAmount.text.trim())},
          ];
          final r = await _send('/brokerage/deals/${d['id']}/decision', {'decision': 'approve', 'shares': shares}, ok: 'اتعتمدت ✅');
          if (!ctx.mounted) return;
          JphUi.toast(ctx, r);
          if (r['success'] == true) {
            Navigator.pop(ctx);
            if (parent.mounted) Navigator.pop(parent);
          }
        });
      }),
    );
  }

  Future<void> _collect(bool isDark, BuildContext parent, Map<String, dynamic> d, String side, dynamic left) async {
    final amount = TextEditingController(text: '${_n(left)}');
    final ref = '${DateTime.now().microsecondsSinceEpoch}';
    final clientRef = _uuidFrom(ref);
    final recipient = ApiService.can('cash.office') ? 'manager' : 'hr';
    await showAppSheet(
      context: parent, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _sheet(isDark, ctx, 'تحصيل عمولة — باقي ${_egp(left)}', [
        JphUi.input(isDark: isDark, label: 'المبلغ', controller: amount, number: true, icon: Icons.payments_rounded, big: false),
      ], 'تحصيل', () async {
        final r = await _send('/brokerage/deals/${d['id']}/collect',
            {'side': side, 'amount': num.tryParse(amount.text.trim()), 'recipient': recipient, 'clientRef': clientRef}, ok: 'اتحصلت ✅');
        if (!ctx.mounted) return;
        JphUi.toast(ctx, r);
        if (r['success'] == true) {
          Navigator.pop(ctx);
          if (parent.mounted) Navigator.pop(parent);
        }
      }),
    );
  }

  /// a v4-shaped UUID for the form's retry key (the same form sent twice → one receipt)
  static String _uuidFrom(String seed) {
    final r = math.Random.secure();
    String h(int n) => List.generate(n, (_) => r.nextInt(16).toRadixString(16)).join();
    return '${h(8)}-${h(4)}-4${h(3)}-${['8', '9', 'a', 'b'][r.nextInt(4)]}${h(3)}-${h(12)}';
  }
}
