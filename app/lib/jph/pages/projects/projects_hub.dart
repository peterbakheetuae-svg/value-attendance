part of '../exclusive/exclusive_projects_page.dart';

/// بند «المشاريع» في الإعدادات: المشاريع / المبيعات / الخزنة / الملاك / العملاء.
///  - المشاريع: صفحة واحدة للنوعين — فلتر «المشاريع / حصري / تسويق»، والإضافة فيها بار «حصري / تسويق».
///  - المبيعات: الحجوزات والتعاقدات في مكان واحد — بار «حجز / تعاقد».

// ==================================================================== المشاريع
class ProjectsPage extends StatelessWidget {
  const ProjectsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    // the «Ardena» holdings page: the whole width, the squares arrange themselves by it
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: app.isDark, isRTL: true, title: 'المشاريع'),
              Expanded(child: ProjectsList(isDark: app.isDark)),
            ]),
          ),
        ),
      ),
    );
  }
}

class ProjectsList extends StatefulWidget {
  final bool isDark;
  const ProjectsList({super.key, required this.isDark});

  @override
  State<ProjectsList> createState() => _ProjectsListState();
}

class _ProjectsListState extends State<ProjectsList> {
  bool _loading = true, _manage = false;
  List<Map<String, dynamic>> _items = [];
  String _kind = ''; // '' = المشاريع (الكل)
  int _sort = 0; // الأحدث / العمولة / المبيعات أو الاسم
  bool _grid = true;
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/projects', {'kind': 'all'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      _items = _l(r['projects']);
      _manage = r['canSetup'] == true;
    });
  }

  Future<void> _add() async {
    final isDark = widget.isDark;
    String kind = _kind.isEmpty ? 'exclusive' : _kind;
    final name = TextEditingController(), owner = TextEditingController(), phone = TextEditingController();
    // المطور: an existing one or a new name
    final devs = _l((await _get('/exclusive/developers'))['developers']);
    Map<String, dynamic>? dev;
    bool newDev = false;
    if (!mounted) return;
    (String, String)? img; // صورة المشروع (اختياري)
    final total = TextEditingController(text: '5'), contract = TextEditingController(text: '3'), sales = TextEditingController(text: '0.2'),
        manager = TextEditingController(text: '0.1'), inst = TextEditingController(text: '0.5'), mkPct = TextEditingController(text: '0');
    num office() => (num.tryParse(total.text) ?? 0) - (num.tryParse(sales.text) ?? 0) - (num.tryParse(manager.text) ?? 0);
    final ok = await _form(context, isDark, 'إضافة مشروع', (set) => [
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'exclusive', label: Text('حصري'), icon: Icon(Icons.apartment_rounded)),
              ButtonSegment(value: 'marketing', label: Text('تسويق'), icon: Icon(Icons.storefront_rounded)),
            ],
            selected: {kind},
            onSelectionChanged: (s) => set(() {
              kind = s.first;
              if (kind == 'marketing' && total.text == '5') total.text = '3';
              if (kind == 'exclusive' && total.text == '3') total.text = '5';
            }),
          ),
          Text(kind == 'exclusive'
                  ? 'المكتب بيستلم كل الفلوس أمانة للمالك، وعمولته على مراحل: عند التعاقد + مع كل قسط.'
                  : 'المكتب بيسوّق لمطور، وعمولته كلها عند التعاقد.',
              style: TextStyle(color: JphUi.sub(isDark), fontSize: 13)),
          JphUi.input(isDark: isDark, label: 'اسم المشروع', controller: name, icon: Icons.apartment_rounded),
          JphUi.picker(
            isDark: isDark,
            icon: Icons.add_photo_alternate_rounded,
            iconColor: Ar.accent,
            label: 'صورة المشروع (اختياري)',
            value: img == null ? 'اختار صورة' : 'اتختارت صورة ✓',
            onTap: () async {
              final x = await _pickProjectImage(context);
              if (x != null) set(() => img = x);
            },
          ),
          // the same picker as «اختار الموظف» in تقرير الحضور
          JphUi.picker(
            isDark: isDark,
            icon: Icons.business_rounded,
            iconColor: Ar.green,
            label: kind == 'exclusive' ? 'المطور (مالك المشروع)' : 'المطور',
            value: dev != null ? '${dev!['name']}' : (newDev ? 'مطور جديد' : 'اختار المطور'),
            onTap: () async {
              final v = await JphUi.sheet<String>(context, isDark, kind == 'exclusive' ? 'المطور (مالك المشروع)' : 'المطور', [
                ('__new__', '+ مطور جديد', Icons.add_business_rounded),
                for (final d in devs) ('${d['id']}', '${d['name']}', Icons.business_rounded),
              ], selected: dev == null ? (newDev ? '__new__' : null) : '${dev!['id']}', icon: Icons.business_rounded);
              if (v == null) return;
              set(() {
                newDev = v == '__new__';
                dev = newDev ? null : devs.firstWhere((d) => '${d['id']}' == v);
                if (dev != null) owner.clear();
              });
            },
          ),
          if (newDev || devs.isEmpty) ...[
            JphUi.input(isDark: isDark, label: 'اسم المطور الجديد', controller: owner, icon: Icons.business_rounded),
            JphUi.input(isDark: isDark, label: 'تليفون المطور', controller: phone, icon: Icons.phone_rounded, number: true),
          ],
          if (kind == 'exclusive') ...[
            const SizedBox.shrink(),
          ],
          JphUi.input(isDark: isDark, label: 'إجمالي العمولة ٪', controller: total, number: true, icon: Icons.percent_rounded),
          if (kind == 'exclusive')
            JphUi.input(isDark: isDark, label: 'منها عند التعاقد ٪', controller: contract, number: true, icon: Icons.handshake_rounded),
          JphUi.input(isDark: isDark, label: 'السيلز ٪', controller: sales, number: true, icon: Icons.person_outline_rounded),
          JphUi.input(isDark: isDark, label: 'مدير المبيعات ٪', controller: manager, number: true, icon: Icons.groups_rounded),
          JphUi.input(isDark: isDark, label: 'عمولة شركات التسويق ٪ (لما العميل يجي من شركة بالعمولة)', controller: mkPct, number: true,
              icon: Icons.campaign_rounded),
          if (kind == 'exclusive')
            JphUi.input(isDark: isDark, label: 'نسبة كل قسط ٪ (افتراضي — تتغير لكل وحدة)', controller: inst, number: true, icon: Icons.event_repeat_rounded),
          AnimatedBuilder(
            animation: Listenable.merge([total, sales, manager]),
            builder: (_, __) => Text('نصيب المكتب: ${JphUi.pct(office())}',
                style: TextStyle(fontWeight: FontWeight.w800, color: Ar.green.shade600)),
          ),
        ], () async {
      final Map<String, dynamic> r;
      if (kind == 'exclusive') {
        r = await _post('/exclusive/projects', {
          'name': name.text.trim(), if (dev != null) 'developerId': dev!['id'] else ...{'developerName': owner.text.trim(), 'developerPhone': phone.text.trim()},
          'totalPct': num.tryParse(total.text), 'contractPct': num.tryParse(contract.text), 'salesPct': num.tryParse(sales.text),
          'managerPct': num.tryParse(manager.text), 'installmentPct': num.tryParse(inst.text), 'marketingPct': num.tryParse(mkPct.text) ?? 0,
        }, 'اتضاف المشروع ✅');
      } else {
        final t = num.tryParse(total.text) ?? 0, sp = num.tryParse(sales.text) ?? 0, mp = num.tryParse(manager.text) ?? 0;
        r = await _post('/exclusive/projects', {
          'kind': 'marketing', 'name': name.text.trim(), 'totalPct': t, 'salesPct': sp, 'managerPct': mp,
          if (dev != null) 'developerId': dev!['id'] else ...{'developerName': owner.text.trim(), 'developerPhone': phone.text.trim()},
          'companyPct': num.parse((t - sp - mp).toStringAsFixed(4)), 'marketingPct': num.tryParse(mkPct.text) ?? 0,
        }, 'اتضاف المشروع ✅');
      }
      if (mounted) JphUi.toast(context, r);
      final id = _m(r['project'])['id'];
      if (r['success'] == true && img != null && id != null && mounted) await _uploadProjectImage(context, '$id', img!);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  bool get _hasStats => _items.any((p) => _m(p['stats']).isNotEmpty);
  String _dev(Map<String, dynamic> p) => '${p['developerName'] ?? p['ownerName'] ?? ''}'.trim();

  List<Map<String, dynamic>> get _shown {
    final q = _q.text.trim();
    final list = _items.where((p) {
      if (q.isNotEmpty && !'${p['name']}'.contains(q) && !_dev(p).contains(q)) return false;
      return _kind.isEmpty || p['kind'] == _kind;
    }).toList();
    switch (_sort) {
      case 1:
        list.sort((a, b) => _n(b['totalPct']).compareTo(_n(a['totalPct'])));
      case 2:
        if (_hasStats) {
          list.sort((a, b) => _n(_m(b['stats'])['sales']).compareTo(_n(_m(a['stats'])['sales'])));
        } else {
          list.sort((a, b) => '${a['name']}'.compareTo('${b['name']}'));
        }
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final shown = _shown;
    final active = _items.where((p) => p['status'] == 'active').length;
    return LayoutBuilder(builder: (context, c) {
      final w = c.maxWidth;
      final wide = w >= 900;
      final pad = wide ? 24.0 : 12.0;
      final cols = math.max(1, ((w - pad * 2 + 16) / (wide ? 320 : 330)).floor());
      const kinds = ['', 'exclusive', 'marketing'];

      final title = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('المشاريع', style: TextStyle(fontSize: wide ? 34 : 26, fontWeight: FontWeight.w600, height: 1.2, color: Glass.ink(isDark))),
        const SizedBox(height: 4),
        Text(_loading ? '...' : '${_items.length} مشروع · $active شغال', style: TextStyle(fontSize: 13.5, color: Glass.muted(isDark))),
      ]);
      final addBtn = _manage
          ? SizedBox(
              height: 44,
              width: wide ? 190 : double.infinity,
              child: ElevatedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add_rounded, size: 20),
                label: const Text('إضافة مشروع', style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Glass.blue,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shadowColor: Glass.blue.withOpacity(0.4),
                  shape: const StadiumBorder(),
                ),
              ),
            )
          : null;
      // الكل / حصري / تسويق — the kind is the GM's and the accountant's only
      final tabBar = _seesKind()
          ? GlassSegments(
              isDark: isDark,
              expand: !wide,
              items: [
                ('الكل', _items.length),
                ('حصري', _items.where((p) => p['kind'] == 'exclusive').length),
                ('تسويق', _items.where((p) => p['kind'] == 'marketing').length),
              ],
              selected: kinds.indexOf(_kind),
              onTap: (i) => setState(() => _kind = kinds[i]),
            )
          : null;
      final search = Container(
        height: 44,
        decoration: Glass.tile(isDark, r: 99),
        child: TextField(
          controller: _q,
          onChanged: (_) => setState(() {}),
          style: TextStyle(fontSize: 16, color: Glass.ink(isDark)),
          decoration: InputDecoration(
            border: InputBorder.none,
            hintText: 'دوّر على مشروع أو مطور',
            hintStyle: TextStyle(color: Glass.muted(isDark)),
            prefixIcon: Icon(Icons.search_rounded, size: 19, color: Glass.muted(isDark)),
            contentPadding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
      );
      final sortBar = GlassSegments(
        isDark: isDark,
        big: false,
        items: [('الأحدث', null), ('العمولة', null), (_hasStats ? 'المبيعات' : 'الاسم', null)],
        selected: _sort,
        onTap: (i) => setState(() => _sort = i),
      );
      final viewBar = GlassSegments(
        isDark: isDark,
        big: false,
        items: const [('▦', null), ('☰', null)],
        selected: _grid ? 0 : 1,
        onTap: (i) => setState(() => _grid = i == 0),
      );

      return RefreshIndicator(
        onRefresh: _load,
        child: ListView(padding: EdgeInsets.fromLTRB(pad, 6, pad, 120), children: [
          if (wide)
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [Expanded(child: title), if (addBtn != null) addBtn])
          else ...[
            title,
            if (addBtn != null) ...[const SizedBox(height: 14), addBtn],
          ],
          const SizedBox(height: 14),
          if (wide)
            Row(children: [
              Expanded(child: tabBar == null ? const SizedBox.shrink() : Align(alignment: AlignmentDirectional.centerStart, child: tabBar)),
              const SizedBox(width: 16),
              SizedBox(width: 300, child: search),
            ])
          else ...[
            if (tabBar != null) ...[tabBar, const SizedBox(height: 12)],
            search,
          ],
          const SizedBox(height: 16),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            Flexible(child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: sortBar)),
            const SizedBox(width: 12),
            viewBar,
          ]),
          const SizedBox(height: 18),
          if (_loading) const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator())),
          if (!_loading && shown.isEmpty)
            Padding(
              padding: const EdgeInsets.all(40),
              child: Text(_items.isEmpty ? 'مفيش مشاريع لسه' : 'مفيش مشروع بالبحث ده',
                  textAlign: TextAlign.center, style: TextStyle(fontSize: 15, color: Glass.muted(isDark))),
            ),
          if (_grid)
            for (var i = 0; i < shown.length; i += cols)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: IntrinsicHeight(
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    for (var j = 0; j < cols; j++) ...[
                      if (j > 0) const SizedBox(width: 16),
                      Expanded(child: i + j < shown.length ? GlassEntrance(key: ValueKey('g${shown[i + j]['id']}'), index: i + j, child: _card(isDark, shown[i + j])) : const SizedBox.shrink()),
                    ],
                  ]),
                ),
              )
          else
            for (final (i, p) in shown.indexed)
              Padding(padding: const EdgeInsets.only(bottom: 12), child: GlassEntrance(key: ValueKey('r${p['id']}'), index: i, child: _row(isDark, p))),
        ]),
      );
    });
  }

  Future<void> _openProject(Map<String, dynamic> p) async {
    await pushSide(context, ExclusiveProjectPage(projectId: '${p['id']}'));
    _load();
  }

  /// the project's picture: a glass-blue scene (our blue, a shade per project) with its initial and a building
  Widget _hero(bool isDark, Map<String, dynamic> p, {double radius = 14, bool small = false}) {
    final name = '${p['name']}';
    final h = name.codeUnits.fold<int>(0, (a, b) => a + b);
    const shades = [
      [Color(0xFFE2501F), Color(0xFF3A1E14)],
      [Color(0xFFD4401A), Color(0xFF2E1A12)],
      [Color(0xFFE04B22), Color(0xFF1C1B19)],
      [Color(0xFFE2501F), Color(0xFF262624)],
      [Color(0xFFFF6A3D), Color(0xFF33190F)],
    ];
    final g = shades[h % shades.length];
    final marketing = p['kind'] == 'marketing';
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: DecoratedBox(
        decoration: BoxDecoration(gradient: LinearGradient(begin: Alignment.topRight, end: Alignment.bottomLeft, colors: g)),
        child: Stack(children: [
          // the building outline
          PositionedDirectional(
            end: small ? -8 : -14,
            bottom: small ? -10 : -18,
            child: Icon(marketing && _seesKind() ? Icons.storefront_rounded : Icons.apartment_rounded,
                size: small ? 70 : 150, color: Colors.white.withOpacity(0.10)),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white.withOpacity(0.10), Colors.transparent, Colors.black.withOpacity(0.25)],
                ),
              ),
            ),
          ),
            Positioned.fill(child: _ProjectPhoto(id: '${p['id']}', at: p['imageAt'])),
          if (!small)
            PositionedDirectional(
              start: 12,
              top: 12,
              child: Row(children: [
                if (p['totalPct'] != null) _heroPill('عمولة ${JphUi.pct(p['totalPct'])}', Glass.good),
                if (_seesKind()) ...[const SizedBox(width: 6), _heroPill(marketing ? 'تسويق' : 'حصري', Colors.white)],
                if (p['status'] != 'active') ...[const SizedBox(width: 6), _heroPill(p['status'] == 'paused' ? 'متوقف' : 'مقفول', Glass.amber)],
              ]),
            ),
        ]),
      ),
    );
  }

  Widget _heroPill(String t, Color c) => ClipRRect(
        borderRadius: BorderRadius.circular(99),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4), // 24px
            color: const Color(0x9E141412),
            child: Text(t, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: c)),
          ),
        ),
      );

  /// the three tiles + the meter, from what this person may see
  (List<(String, String)>, double?, String, Color) _figures(Map<String, dynamic> p) {
    final st = _m(p['stats']);
    final marketing = p['kind'] == 'marketing';
    if (st.isEmpty) {
      return ([
        ('العمولة', JphUi.pct(p['totalPct'])),
        ('السيلز', JphUi.pct(p['salesPct'])),
        (marketing ? 'النوع' : 'عند التعاقد', marketing ? 'تسويق' : JphUi.pct(p['contractPct'])),
      ], null, '', Glass.good);
    }
    final u = _m(st['units']), cm = _m(st['commission']), ow = _m(st['owner']);
    final sold = _n(u['contracted']) + _n(u['completed']);
    final live = _n(u['total']) - _n(u['cancelled']);
    return ([
      ('المبيعات', _short(st['sales'])),
      ('محجوز', '${u['reserved'] ?? 0}'),
      marketing ? ('نصيب المكتب', _short(cm['office'])) : ('في الأمانة', _short(ow['inTrust'])),
    ], live <= 0 ? 0 : sold / live, live <= 0 ? 'مفيش وحدات' : '${sold.toInt()}/${live.toInt()} اتباع',
        live > 0 && sold >= live ? Glass.good : Glass.amber);
  }

  static String _short(Object? v) {
    final n = _n(v);
    if (n.abs() >= 1e6) return '${(n / 1e6).toStringAsFixed(n.abs() >= 1e7 ? 1 : 2)} مليون';
    if (n.abs() >= 1e3) return '${(n / 1e3).toStringAsFixed(0)} ألف';
    return JphUi.money(n);
  }

  Widget _card(bool isDark, Map<String, dynamic> p) {
    final (tiles, meter, meterLabel, meterColor) = _figures(p);
    final dev = _dev(p);
    return GlassBox(
      isDark: isDark,
      radius: 18,
      padding: const EdgeInsets.all(8),
      onTap: () => _openProject(p),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        AspectRatio(aspectRatio: 1.6, child: _hero(isDark, p)),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 14, 8, 8), // the site: 14 / 16 / 16 from the card's edge
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${p['name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Glass.ink(isDark))),
            const SizedBox(height: 2),
            Text(dev.isEmpty ? 'بدون مطور' : 'المطور: $dev', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Glass.muted(isDark))),
            const SizedBox(height: 12),
            Row(children: [
              for (final (i, t) in tiles.indexed) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: GlassStat(isDark: isDark, label: t.$1, value: t.$2)),
              ],
            ]),
            if (meter != null) ...[
              const SizedBox(height: 12),
              Row(children: [
                Text(meterLabel, style: TextStyle(fontSize: 12, color: Glass.muted(isDark), fontWeight: FontWeight.w600)),
                const SizedBox(width: 12),
                Expanded(child: GlassMeter(isDark: isDark, value: meter, color: meterColor)),
              ]),
            ],
          ]),
        ),
      ]),
    );
  }

  /// the list view: one line per project
  Widget _row(bool isDark, Map<String, dynamic> p) {
    final (tiles, meter, meterLabel, meterColor) = _figures(p);
    final dev = _dev(p);
    return GlassBox(
      isDark: isDark,
      radius: 20,
      padding: const EdgeInsets.all(8),
      onTap: () => _openProject(p),
      child: Row(children: [
        SizedBox(width: 80, height: 80, child: _hero(isDark, p, small: true)),
        const SizedBox(width: 14),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${p['name']}', maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Glass.ink(isDark))),
            const SizedBox(height: 2),
            Text(dev.isEmpty ? 'بدون مطور' : dev, maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: Glass.muted(isDark))),
            const SizedBox(height: 8),
            Text(tiles.map((t) => '${t.$1}: ${t.$2}').join('  ·  '),
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: Glass.ink(isDark))),
            if (meter != null) ...[
              const SizedBox(height: 8),
              Row(children: [
                Text(meterLabel, style: TextStyle(fontSize: 12, color: Glass.muted(isDark))),
                const SizedBox(width: 8),
                Expanded(child: GlassMeter(isDark: isDark, value: meter, color: meterColor)),
              ]),
            ],
          ]),
        ),
        const SizedBox(width: 6),
        Icon(Icons.chevron_left_rounded, color: Glass.muted(isDark)),
      ]),
    );
  }
}

/// The bar on top of a list (حصري / تسويق — حجز / تعاقد): pill segments in the app's colours.
class _KindBar extends StatelessWidget {
  final bool isDark;
  final String value;
  final List<(String, String)> options;
  final Map<String, int>? counts;
  final ValueChanged<String> onChanged;
  const _KindBar({required this.isDark, required this.value, required this.options, required this.onChanged, this.counts});

  @override
  Widget build(BuildContext context) {
    final p = JphUi.primary(isDark);
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: Glass.tile(isDark, r: 30),
      child: Row(children: [
        for (final o in options)
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(o.$1),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: value == o.$1 ? p : Colors.transparent,
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: value == o.$1 ? [BoxShadow(color: p.withOpacity(0.3), blurRadius: 10, offset: const Offset(0, 4))] : null,
                ),
                child: Text(
                  counts == null ? o.$2 : '${o.$2} (${counts![o.$1] ?? 0})',
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  style: TextStyle(fontWeight: FontWeight.w800, color: value == o.$1 ? Colors.white : JphUi.text(isDark)),
                ),
              ),
            ),
          ),
      ]),
    );
  }
}

// ==================================================================== المبيعات (حجز / تعاقد)
class SalesHubPage extends StatelessWidget {
  const SalesHubPage({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return _Shell(title: 'المبيعات', child: UnifiedSalesTab(isDark: app.isDark));
  }
}

class UnifiedSalesTab extends StatefulWidget {
  final bool isDark;
  const UnifiedSalesTab({super.key, required this.isDark});

  @override
  State<UnifiedSalesTab> createState() => _UnifiedSalesTabState();
}

class _UnifiedSalesTabState extends State<UnifiedSalesTab> {
  String _stage = 'reservation';
  String _kind = '';
  bool _loading = true, _reserve = false;
  List<Map<String, dynamic>> _units = [], _projects = [], _pending = [];
  bool _canReceive = false;
  String _into = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await Future.wait([
      _get('/exclusive/units', {'stage': _stage, if (_kind.isNotEmpty) 'kind': _kind}),
      _get('/exclusive/payments'),
      if (_projects.isEmpty) _get('/exclusive/projects', {'kind': 'all'}),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _units = _l(r[0]['units']);
      _pending = _l(r[1]['payments']);
      _canReceive = r[1]['canReceive'] == true;
      _into = '${r[1]['into'] ?? ''}';
      if (r.length > 2) {
        _projects = _l(r[2]['projects']);
        _reserve = r[2]['canReserve'] == true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final waiting = _units.where((u) => ['reserving', 'contract_pending', 'cancel_pending'].contains(u['status'])).length;
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        _KindBar(
          isDark: isDark,
          value: _stage,
          options: const [('reservation', 'حجز'), ('contract', 'تعاقد')],
          onChanged: (v) {
            setState(() => _stage = v);
            _load();
          },
        ),
        const SizedBox(height: 10),
        // the money the sales brought in, waiting for «تم استلام المبلغ»
        if (_pending.isNotEmpty) ...[
          _section(isDark, _canReceive ? 'مبالغ مستنية تأكيد الاستلام (${_pending.length})' : 'مستني تأكيد الاستلام', [
            for (final x in _pending)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(children: [
                  const Icon(Icons.hourglass_top_rounded, color: Ar.amber),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${x['kindAr']} — ${x['projectName']} · وحدة ${x['unitNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                      Text('${x['clientName']} · ${x['salesName']}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    CountUpText(_money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    if (_canReceive)
                      TextButton(onPressed: () => _receive(isDark, x), child: const Text('تم الاستلام', style: TextStyle(fontWeight: FontWeight.w900))),
                  ]),
                ]),
              ),
          ]),
        ],
        // the same bar as حجز / تعاقد (حصري / تسويق: المالك / المدير العام and the accountant only)
        if (_seesKind())
          _KindBar(
            isDark: isDark,
            value: _kind,
            options: const [('', 'كل المشاريع'), ('exclusive', 'حصري'), ('marketing', 'تسويق')],
            onChanged: (v) {
              setState(() => _kind = v);
              _load();
            },
          ),
        const SizedBox(height: 10),
        if (_reserve && _projects.isNotEmpty)
          _btn(isDark, _stage == 'reservation' ? 'حجز جديد' : 'تعاقد جديد', _stage == 'reservation' ? Icons.bookmark_add_rounded : Icons.handshake_rounded,
              () => newUnit(context, isDark, _projects.where((p) => _kind.isEmpty || p['kind'] == _kind).toList(),
                  contract: _stage == 'contract', then: _load),
              color: _stage == 'reservation' ? Ar.green : JphUi.primary(isDark)),
        if (_stage == 'reservation')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('الحجز بيتحوّل لتعاقد من صفحة الوحدة (دوس على الحجز).', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
          ),
        if (_stage == 'reservation' && waiting > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('$waiting حجز مستني إجراء', style: const TextStyle(color: Ar.amber, fontWeight: FontWeight.w800)),
          ),
        const SizedBox(height: 6),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && _units.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text(_stage == 'reservation' ? 'مفيش حجوزات' : 'مفيش تعاقدات',
              textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final u in _units) _unitCard(isDark, u),
      ]),
    );
  }

  Future<void> _receive(bool isDark, Map<String, dynamic> x) async {
    final method = await _askCashOrBank(context, 'تم استلام ${x['kindAr']}',
        '${_money(x['amount'])}\n${x['projectName']} · وحدة ${x['unitNo']} · ${x['clientName']}\nهيدخل $_into');
    if (method == null) return;
    final r = await _post('/exclusive/payments/${x['id']}/receive', {'paymentMethod': method}, 'اتأكد الاستلام ✅');
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  Widget _unitCard(bool isDark, Map<String, dynamic> x) {
    final money = _m(x['money']);
    final st = '${x['status']}';
    final marketing = x['projectKind'] == 'marketing';
    final inst = _m(x['installments']);
    return GestureDetector(
      onTap: () async {
        await pushSide(context, ExclusiveUnitPage(unitId: '${x['id']}'));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Row(children: [
          JphUi.iconTile(isDark, marketing && _seesKind() ? Icons.storefront_rounded : Icons.home_work_rounded, _statusColor(st)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text('${x['projectName']} — وحدة ${x['unitNo']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                _pill('${x['statusAr']}', _statusColor(st)),
              ]),
              const SizedBox(height: 3),
              Text('${x['clientName']} · ${x['salesName']}${x['marketingCompanyName'] != null ? ' · عن طريق ${x['marketingCompanyName']}' : ''}',
                  style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
              const SizedBox(height: 3),
              Text('${_money(x['unitPrice'])}${marketing ? '' : ' · اتحصّل ${_money(money['collected'])}'}'
                  '${_n(inst['total']) > 0 ? ' · أقساط ${inst['paid']}/${inst['total']}' : ''}',
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              if (_m(x['commission']).isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(spacing: 6, children: [
                  if (_n(_m(x['commission'])['potential']) > 0) _pill('عمولة محتملة ${_money(_m(x['commission'])['potential'])}', Ar.accent),
                  if (_n(_m(x['commission'])['receivable']) > 0) _pill('واجبة التحصيل ${_money(_m(x['commission'])['receivable'])}', Ar.amber),
                  if (st != 'reserved' && _n(_m(x['commission'])['receivable']) == 0 && _n(_m(x['commission'])['collected']) > 0)
                    _pill('العمولة اتحصّلت', Ar.green),
                ]),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

// ==================================================================== الملاك
class OwnersPage extends StatefulWidget {
  const OwnersPage({super.key});

  @override
  State<OwnersPage> createState() => _OwnersPageState();
}

class _OwnersPageState extends State<OwnersPage> {
  Map<String, dynamic>? _d;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/owners');
    if (mounted) setState(() => _d = r);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final owners = _l(_d?['owners']);
    return _Shell(
      title: 'الملاك',
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['success'] != true
              ? Center(child: Text('${_d!['message'] ?? 'مش متاح'}'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                    if (owners.isEmpty)
                      Padding(padding: const EdgeInsets.all(30), child: Text('لسه مفيش ملاك (الملاك بيتسجلوا مع المشاريع الحصري)',
                          textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                    for (final o in owners)
                      _section(isDark, '${o['name']}', [
                        if ('${o['phone'] ?? ''}'.isNotEmpty) _kv(isDark, 'التليفون', '${o['phone']}'),
                        _kv(isDark, 'الوحدات', '${o['units']}'),
                        _kv(isDark, 'المبيعات', _money(o['sales'])),
                        _kv(isDark, 'اتحصّل (أمانة)', _money(o['collected'])),
                        _kv(isDark, 'عمولة اتحوّلت للمكتب', _money(o['commissionTransferred'])),
                        _kv(isDark, 'اتصرف للمالك', _money(o['paid']), color: Ar.green),
                        const Divider(),
                        _kv(isDark, 'في الأمانة دلوقتي', _money(o['inTrust'])),
                        _kv(isDark, 'الصافي المستحق للمالك', _money(o['due']), color: Ar.green),
                        const SizedBox(height: 6),
                        for (final p in _l(o['projects']))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.apartment_rounded, color: Ar.accent),
                            title: Text('${p['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                            subtitle: Text('مستحق ${_money(p['due'])}', style: TextStyle(color: JphUi.sub(isDark))),
                            trailing: Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
                            onTap: () => pushSide(context, ExclusiveProjectPage(projectId: '${p['id']}'))
                                .then((_) => _load()),
                          ),
                      ]),
                  ]),
                ),
    );
  }
}

// ==================================================================== العملاء
class ClientsPage extends StatefulWidget {
  const ClientsPage({super.key});

  @override
  State<ClientsPage> createState() => _ClientsPageState();
}

class _ClientsPageState extends State<ClientsPage> {
  Map<String, dynamic>? _d;
  final _q = TextEditingController();
  // المدير العام / المحاسب: فلتر بالسيلز والمشروع والشهر
  String? _sales, _project;
  DateTime? _month;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/clients');
    if (mounted) setState(() => _d = r);
  }

  /// every client on his own card: one card per client per unit (never merged)
  List<Map<String, dynamic>> get _rows => [
        for (final c in _l(_d?['clients']))
          for (final u in _l(c['units'])) {...u, 'clientName': c['name'], 'clientPhone': c['phone']},
      ]..sort((a, b) => '${b['at'] ?? ''}'.compareTo('${a['at'] ?? ''}'));

  bool _inMonth(Map<String, dynamic> u) {
    if (_month == null) return true;
    final d = DateTime.tryParse('${u['at'] ?? ''}')?.toLocal();
    return d != null && d.year == _month!.year && d.month == _month!.month;
  }

  Future<void> _filter(bool isDark) async {
    final rows = _rows;
    final sales = <String, String>{for (final u in rows) if (u['salesId'] != null) '${u['salesId']}': '${u['salesName'] ?? ''}'};
    final projects = <String, String>{for (final u in rows) if (u['projectId'] != null) '${u['projectId']}': '${u['projectName'] ?? ''}'};
    final v = await JphUi.sheet<String>(context, isDark, 'الفلتر', [
      ('sales', 'السيلز: ${_sales == null ? 'الكل' : sales[_sales] ?? ''}', Icons.person_rounded),
      ('project', 'المشروع: ${_project == null ? 'الكل' : projects[_project] ?? ''}', Icons.apartment_rounded),
      ('month', 'الشهر: ${monthLabel(_month)}', Icons.calendar_month_rounded),
      if (_sales != null || _project != null || _month != null) ('clear', 'مسح الفلتر', Icons.filter_alt_off_rounded),
    ], icon: Icons.filter_list_rounded);
    if (v == null || !mounted) return;
    switch (v) {
      case 'sales':
        final s = await JphUi.sheet<String>(context, isDark, 'السيلز', [
          ('all', 'كل السيلز', Icons.groups_rounded),
          for (final e in sales.entries) (e.key, e.value, Icons.person_rounded),
        ], selected: _sales ?? 'all', icon: Icons.person_rounded, people: true);
        if (s != null) setState(() => _sales = s == 'all' ? null : s);
      case 'project':
        final s = await JphUi.sheet<String>(context, isDark, 'المشروع', [
          ('all', 'كل المشاريع', Icons.all_inclusive_rounded),
          for (final e in projects.entries) (e.key, e.value, Icons.apartment_rounded),
        ], selected: _project ?? 'all', icon: Icons.apartment_rounded);
        if (s != null) setState(() => _project = s == 'all' ? null : s);
      case 'month':
        final m = await JphUi.pickMonthOrAll(context, isDark, _month);
        if (m != null) setState(() => _month = identical(m, JphUi.allMonths) ? null : m);
      case 'clear':
        setState(() {
          _sales = null;
          _project = null;
          _month = null;
        });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final q = _q.text.trim();
    final seesAll = _d?['seesAll'] == true;
    final rows = _rows
        .where((u) => q.isEmpty || '${u['clientName']}'.contains(q) || '${u['clientPhone'] ?? ''}'.contains(q))
        .where((u) => _sales == null || '${u['salesId']}' == _sales)
        .where((u) => _project == null || '${u['projectId']}' == _project)
        .where(_inMonth)
        .toList();
    final filtered = _sales != null || _project != null || _month != null;
    return _Shell(
      title: 'العملاء',
      action: seesAll ? SquareIconButton(icon: Icons.filter_list_rounded, onTap: () => _filter(isDark), isDark: isDark) : null,
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['success'] != true
              ? Center(child: Text('${_d!['message'] ?? 'مش متاح'}'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                    JphUi.input(isDark: isDark, label: 'دوّر باسم العميل أو تليفونه', controller: _q, icon: Icons.search_rounded, onChanged: (_) => setState(() {})),
                    if (filtered)
                      Padding(
                        padding: const EdgeInsets.only(top: 10),
                        child: Text(
                            [
                              if (_sales != null) 'السيلز: ${rows.isNotEmpty ? rows.first['salesName'] : ''}',
                              if (_project != null) 'المشروع: ${rows.isNotEmpty ? rows.first['projectName'] : ''}',
                              if (_month != null) monthLabel(_month),
                            ].join(' • '),
                            textAlign: TextAlign.center,
                            style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
                      ),
                    const SizedBox(height: 12),
                    Text('${rows.length} عميل', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
                    const SizedBox(height: 8),
                    if (rows.isEmpty)
                      Padding(padding: const EdgeInsets.all(30), child: Text('مفيش عملاء', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                    // every client on his own card: his name, phone and where he stands; tap → all his details
                    for (final u in rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: GlassBox(
                          isDark: isDark,
                          radius: 18,
                          padding: const EdgeInsets.all(14),
                          onTap: u['source'] == 'unit'
                              ? () => pushSide(context, ExclusiveUnitPage(unitId: '${u['id']}')).then((_) => _load())
                              : null,
                          child: Row(children: [
                            JphUi.iconTile(isDark, Icons.person_rounded, _clientColor('${u['status']}')),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                Text('${u['clientName']}', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                                const SizedBox(height: 2),
                                Text('${u['clientPhone'] ?? ''}'.isEmpty ? 'بدون تليفون' : '${u['clientPhone']}',
                                    textDirection: ui.TextDirection.ltr, style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                              ]),
                            ),
                            _pill(_clientState('${u['status']}'), _clientColor('${u['status']}')),
                          ]),
                        ),
                      ),
                  ]),
                ),
    );
  }
}

/// حاجز / متعاقد / فاضي (a cancelled reservation leaves the client with nothing)
String _clientState(String st) => switch (st) {
      'contracted' || 'completed' => 'متعاقد',
      'cancelled' => 'فاضي',
      _ => 'حاجز',
    };
Color _clientColor(String st) => switch (st) {
      'contracted' || 'completed' => Ar.green,
      'cancelled' => Ar.grey,
      _ => Ar.amber,
    };

// ==================================================================== الخزنة: خزنة المشاريع / العمولات / عمولات متوقعة
// Each tile on the cashbox opens a full page (not a sheet) with all the details.

Future<Map<String, dynamic>> _overview([DateTime? month]) => _get('/cash/overview', monthQuery(month));

/// null = كل الشهور; a month → its first..last day.
Map<String, String> monthQuery(DateTime? m) {
  if (m == null) return {};
  String d(DateTime x) => '${x.year}-${x.month.toString().padLeft(2, '0')}-${x.day.toString().padLeft(2, '0')}';
  return {'from': d(DateTime(m.year, m.month)), 'to': d(DateTime(m.year, m.month + 1, 0))};
}

String monthLabel(DateTime? m) => m == null ? 'كل الشهور' : '${JphUi.monthsAr[m.month - 1]} ${m.year}';

/// The month filter of the cashbox tiles and their pages: «كل الشهور» by default, or one month.
class MonthFilterBar extends StatelessWidget {
  final bool isDark;
  final DateTime? month;
  final ValueChanged<DateTime?> onChanged;
  const MonthFilterBar({super.key, required this.isDark, required this.month, required this.onChanged});

  /// The same filter icon as the pages' header: «كل الشهور» first, then the months.
  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final months = [for (var i = -24; i <= 12; i++) DateTime(now.year, now.month + i)].reversed.toList();
    final v = await JphUi.sheet<String>(context, isDark, 'الفلتر', [
      ('all', 'كل الشهور', Icons.all_inclusive_rounded),
      for (final m in months) ('${m.year}-${m.month}', monthLabel(m), m.year == now.year && m.month == now.month ? Icons.today_rounded : Icons.calendar_month_rounded),
    ], selected: month == null ? 'all' : '${month!.year}-${month!.month}');
    if (v == null) return;
    if (v == 'all') return onChanged(null);
    final p = v.split('-');
    onChanged(DateTime(int.parse(p[0]), int.parse(p[1])));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          Icon(month == null ? Icons.all_inclusive_rounded : Icons.calendar_month_rounded, color: JphUi.sub(isDark), size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(monthLabel(month), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: JphUi.text(isDark)))),
          SquareIconButton(icon: Icons.filter_list_rounded, onTap: () => _pick(context), isDark: isDark),
        ]),
      );
}

Widget _tile(bool isDark, String label, Object? value, IconData icon, Color color, {VoidCallback? onTap}) =>
    GestureDetector(onTap: onTap, child: JphUi.stat(isDark, label, _money(value), icon, color));

Widget _mini(bool isDark, String label, Object? v, Color color) => Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
      decoration: BoxDecoration(color: color.withOpacity(isDark ? 0.18 : 0.09), borderRadius: BorderRadius.circular(12)),
      child: Column(children: [
        Text(label, style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
        FittedBox(fit: BoxFit.scaleDown, child: CountUpText(_money(v), style: TextStyle(fontWeight: FontWeight.w900, color: color))),
      ]),
    );

String _ym(String ym) {
  if (ym.length < 7) return 'من غير تاريخ متوقع';
  final m = int.tryParse(ym.substring(5, 7)) ?? 1;
  return '${JphUi.monthsAr[m - 1]} ${ym.substring(0, 4)}';
}

abstract class _OverviewPageState<T extends StatefulWidget> extends State<T> {
  Map<String, dynamic>? o;
  DateTime? month; // null = كل الشهور
  DateTime? get initialMonth => null;
  @override
  void initState() {
    super.initState();
    month = initialMonth;
    load();
  }

  Future<void> load() async {
    final r = await _overview(month);
    if (mounted) setState(() => o = r);
  }

  Future<void> pickFilter(bool isDark) async {
    final m = await JphUi.pickMonthOrAll(context, isDark, month);
    if (m == null) return;
    setState(() {
      month = identical(m, JphUi.allMonths) ? null : m;
      o = null;
    });
    load();
  }

  /// the header's filter icon (the same square as the other pages)
  Widget filterIcon(bool isDark) => SquareIconButton(icon: Icons.filter_list_rounded, onTap: () => pickFilter(isDark), isDark: isDark);

  Widget filter(bool isDark) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(monthLabel(month), textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
      );

  String get title;
  List<Widget> body(bool isDark);

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return _Shell(
      title: title,
      action: filterIcon(isDark),
      child: o == null
          ? const Center(child: CircularProgressIndicator())
          : o!['success'] != true
              ? Center(child: Text('${o!['message'] ?? 'مش متاح'}'))
              : RefreshIndicator(onRefresh: load, child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [filter(isDark), ...body(isDark)])),
    );
  }
}

// -------------------------------------------------------------------- خزنة المشاريع
class ProjectsBoxPage extends StatefulWidget {
  final DateTime? month;
  const ProjectsBoxPage({super.key, this.month});
  @override
  State<ProjectsBoxPage> createState() => _ProjectsBoxPageState();
}

class _ProjectsBoxPageState extends _OverviewPageState<ProjectsBoxPage> {
  @override
  DateTime? get initialMonth => widget.month;
  @override
  String get title => 'خزنة المشاريع';

  @override
  List<Widget> body(bool isDark) {
    final box = _m(o!['projectsBox']);
    final ps = _l(box['projects']);
    num sum(String k) => ps.fold<num>(0, (t, p) => t + _n(p[k]));
    return [
      JphUi.statGrid([
        _tile(isDark, 'إجمالي الأمانات', box['total'], Icons.real_estate_agent_rounded, Ar.accent),
        _tile(isDark, 'من الحجوزات', sum('reservation'), Icons.bookmark_rounded, Ar.green),
        _tile(isDark, 'من التعاقد', sum('contract'), Icons.handshake_rounded, Ar.accent),
        _tile(isDark, 'من الأقساط', sum('installments'), Icons.event_repeat_rounded, Ar.info),
        _tile(isDark, 'اتصرف للملاك', sum('paidToOwner'), Icons.outbox_rounded, Ar.red),
        _tile(isDark, 'الصافي للملاك', sum('ownerDue'), Icons.account_balance_rounded, Ar.green),
      ]),
      const SizedBox(height: 16),
      Text('المشاريع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      const SizedBox(height: 8),
      if (ps.isEmpty)
        Padding(padding: const EdgeInsets.all(30), child: Text('مفيش مشاريع حصري', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      for (final p in ps)
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectTrustPage(project: p, month: month))).then((_) => load()),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: JphUi.box(isDark),
            child: Row(children: [
              JphUi.iconTile(isDark, Icons.apartment_rounded, Ar.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text('المالك: ${p['ownerName'] ?? '—'}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                CountUpText(_money(p['inTrust']), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Ar.accent)),
                Text('أمانات', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
              ]),
              Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
            ]),
          ),
        ),
    ];
  }
}

/// One project's trust in full: what came in (حجز / تعاقد / أقساط), what went to the owner, the owner's statement and units.
class ProjectTrustPage extends StatefulWidget {
  final Map<String, dynamic> project;
  final DateTime? month;
  const ProjectTrustPage({super.key, required this.project, this.month});
  @override
  State<ProjectTrustPage> createState() => _ProjectTrustPageState();
}

class _ProjectTrustPageState extends _OverviewPageState<ProjectTrustPage> {
  Map<String, dynamic>? _d;
  @override
  DateTime? get initialMonth => widget.month;
  @override
  String get title => '${widget.project['name']}';

  @override
  Future<void> load() async {
    final r = await Future.wait([_overview(month), _get('/exclusive/projects/${widget.project['id']}')]);
    if (mounted) {
      setState(() {
        o = r[0];
        _d = r[1];
      });
    }
  }

  @override
  List<Widget> body(bool isDark) {
    final p = _l(_m(o!['projectsBox'])['projects']).firstWhere((x) => x['id'] == widget.project['id'], orElse: () => widget.project);
    final units = _l(_d?['units']);
    final range = monthQuery(month);
    final statement = _l(_d?['statement']).where((s) {
      if (range.isEmpty) return true;
      final d = '${s['at'] ?? ''}';
      final day = d.length >= 10 ? (DateTime.tryParse(d)?.toLocal().toIso8601String().substring(0, 10) ?? d.substring(0, 10)) : '';
      return day.compareTo(range['from']!) >= 0 && day.compareTo(range['to']!) <= 0;
    }).toList();
    return [
      Text('المالك / المطور: ${p['ownerName'] ?? '—'}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      JphUi.statGrid([
        _tile(isDark, 'موجود أمانات (دلوقتي)', p['inTrust'], Icons.real_estate_agent_rounded, Ar.accent),
        _tile(isDark, 'من الحجز', p['reservation'], Icons.bookmark_rounded, Ar.green),
        _tile(isDark, 'من التعاقد', p['contract'], Icons.handshake_rounded, Ar.accent),
        _tile(isDark, 'من الأقساط', p['installments'], Icons.event_repeat_rounded, Ar.info),
        _tile(isDark, 'للمالك / المطور (صافي دلوقتي)', p['ownerDue'], Icons.account_balance_rounded, Ar.green),
        _tile(isDark, 'اتصرف للمالك / المطور', p['paidToOwner'], Icons.outbox_rounded, Ar.red),
        _tile(isDark, 'عمولة اتحوّلت للمكتب', p['commissionMoved'], Icons.workspace_premium_rounded, Ar.amber.shade800),
        if (_n(p['refunded']) > 0) _tile(isDark, 'اترد لعملاء لغوا', p['refunded'], Icons.undo_rounded, Ar.amber),
        if (_n(p['pendingPayout']) > 0) _tile(isDark, 'صرف مستني الموافقة', p['pendingPayout'], Icons.hourglass_top_rounded, Ar.amber),
      ]),
      const SizedBox(height: 16),
      if (_d == null) const Padding(padding: EdgeInsets.all(20), child: Center(child: CircularProgressIndicator())),
      if (units.isNotEmpty)
        _section(isDark, 'الوحدات (${units.length})', [
          for (final u in units)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.home_work_rounded, color: _statusColor('${u['status']}')),
              title: Text('وحدة ${u['unitNo']} — ${u['clientName']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              subtitle: Text('${u['statusAr']} · دفع ${_money(_m(u['money'])['collected'])} من ${_money(u['unitPrice'])}',
                  style: TextStyle(color: JphUi.sub(isDark))),
              trailing: Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
              onTap: () => pushSide(context, ExclusiveUnitPage(unitId: '${u['id']}')).then((_) => load()),
            ),
        ]),
      _section(isDark, 'كشف حساب المالك${month == null ? '' : ' — ${monthLabel(month)}'}', [
        if (statement.isEmpty) Text('مفيش حركات', style: TextStyle(color: JphUi.sub(isDark))),
        for (final s in statement)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Icon(s['dir'] == 'in' ? Icons.south_west_rounded : Icons.north_east_rounded, color: s['dir'] == 'in' ? Ar.green : Ar.red, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${s['typeAr']}${s['unitNo'] != null ? ' — وحدة ${s['unitNo']}' : ''} · ${_date(s['at'])}',
                    style: TextStyle(color: JphUi.text(isDark))),
              ),
              CountUpText(_money(s['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: s['dir'] == 'in' ? Ar.green : Ar.red)),
            ]),
          ),
      ]),
    ];
  }
}

// -------------------------------------------------------------------- العمولات
class CommissionsDuePage extends StatefulWidget {
  final DateTime? month;
  const CommissionsDuePage({super.key, this.month});
  @override
  State<CommissionsDuePage> createState() => _CommissionsDuePageState();
}

class _CommissionsDuePageState extends _OverviewPageState<CommissionsDuePage> {
  @override
  DateTime? get initialMonth => widget.month;
  @override
  String get title => 'العمولات';

  @override
  List<Widget> body(bool isDark) {
    final c = _m(o!['commissions']);
    return [
      JphUi.statGrid([
        _tile(isDark, 'إجمالي العمولة المستحقة', c['due'], Icons.workspace_premium_rounded, Ar.amber.shade800),
        _tile(isDark, 'دخلت خزنة العمولات', c['collected'], Icons.savings_rounded, Ar.green),
        _tile(isDark, 'متبقي لم يتم أخذه', c['remaining'], Icons.hourglass_top_rounded, Ar.amber),
        _tile(isDark, 'جاية من أقساط لسه', c['upcoming'], Icons.event_repeat_rounded, Ar.accent),
      ]),
      const SizedBox(height: 16),
      Text('المشاريع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
      const SizedBox(height: 8),
      for (final p in _l(c['byProject']))
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ProjectCommissionsPage(project: p, month: month))).then((_) => load()),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, p['kind'] == 'marketing' ? Icons.storefront_rounded : Icons.apartment_rounded,
                    p['kind'] == 'marketing' ? Ar.accent : Ar.accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text(p['kind'] == 'marketing' ? 'تسويق' : 'حصري', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  CountUpText(_money(p['remaining']), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Ar.amber)),
                  Text('متبقي', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                ]),
                Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _mini(isDark, 'الإجمالي', p['due'], Ar.amber.shade800)),
                const SizedBox(width: 6),
                Expanded(child: _mini(isDark, 'دخلت', p['collected'], Ar.green)),
                const SizedBox(width: 6),
                Expanded(child: _mini(isDark, 'متوقعة', p['expected'], Ar.green)),
              ]),
            ]),
          ),
        ),
      if (_n(_m(c['legacy'])['due']) > 0)
        _section(isDark, 'عمولات صفقات قديمة (من غير وحدة)', [
          _kv(isDark, 'مستحقة', _money(_m(c['legacy'])['due'])),
          _kv(isDark, 'دخلت', _money(_m(c['legacy'])['collected']), color: Ar.green),
        ]),
    ];
  }
}

// -------------------------------------------------------------------- عمولات متوقعة
class ExpectedCommissionsPage extends StatefulWidget {
  final DateTime? month;
  const ExpectedCommissionsPage({super.key, this.month});
  @override
  State<ExpectedCommissionsPage> createState() => _ExpectedCommissionsPageState();
}

class _ExpectedCommissionsPageState extends _OverviewPageState<ExpectedCommissionsPage> {
  @override
  DateTime? get initialMonth => widget.month;
  @override
  String get title => 'عمولات متوقعة';

  @override
  List<Widget> body(bool isDark) {
    final e = _m(o!['expectedCommissions']);
    final months = _l(e['months']);
    return [
      Text('من الحجوزات، في شهر «التاريخ المتوقع للتعاقد» المكتوب في فورم الحجز', style: TextStyle(color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      JphUi.statGrid([
        _tile(isDark, 'إجمالي المتوقع', e['total'], Icons.event_available_rounded, Ar.accent),
        for (final m in months.take(5)) _tile(isDark, _ym('${m['month']}'), m['amount'], Icons.calendar_month_rounded, Ar.green),
      ]),
      const SizedBox(height: 16),
      if (months.isEmpty)
        Padding(padding: const EdgeInsets.all(30), child: Text('مفيش حجوزات مفتوحة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      for (final m in months)
        _section(isDark, '${_ym('${m['month']}')} — ${_money(m['amount'])}', [
          for (final u in _l(m['units']))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bookmark_rounded, color: Ar.accent),
              title: Text('${u['projectName']} — وحدة ${u['unitNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              subtitle: Text('${u['clientName']} · ${u['salesName']}${u['expectedContractDate'] != null ? ' · تعاقد متوقع ${_date(u['expectedContractDate'])}' : ''}',
                  style: TextStyle(color: JphUi.sub(isDark))),
              trailing: CountUpText(_money(u['amount']), style: const TextStyle(fontWeight: FontWeight.w900, color: Ar.accent)),
              onTap: () => pushSide(context, ExclusiveUnitPage(unitId: '${u['id']}')).then((_) => load()),
            ),
        ]),
    ];
  }
}

// ==================================================================== «تم استلام المبلغ» — on the home screen and the cashbox
/// The money the sales brought in (عربون حجز / مقدم تعاقد), waiting for the accountant or المالك / المدير العام —
/// shown like a leave / advance request: a card on top, and a popup the first time a new one appears.
class PendingSalesMoneyCard extends StatefulWidget {
  final VoidCallback? onChanged;
  const PendingSalesMoneyCard({super.key, this.onChanged});
  @override
  State<PendingSalesMoneyCard> createState() => _PendingSalesMoneyCardState();
}

class _PendingSalesMoneyCardState extends State<PendingSalesMoneyCard> {
  static final Set<String> _popped = {}; // once per app session for each payment
  List<Map<String, dynamic>> _items = [];
  String _into = '';
  Timer? _timer;

  bool get _can => ApiService.can('cash.office') || ApiService.can('cash.hr_operate');

  @override
  void initState() {
    super.initState();
    if (!_can) return;
    _load();
    _timer = Timer.periodic(const Duration(seconds: 45), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/payments');
    if (!mounted || r['success'] != true || r['canReceive'] != true) return;
    final items = _l(r['payments']);
    setState(() {
      _items = items;
      _into = '${r['into'] ?? ''}';
    });
    final fresh = items.where((x) => !_popped.contains('${x['id']}')).toList();
    if (fresh.isNotEmpty) {
      _popped.addAll(fresh.map((x) => '${x['id']}'));
      WidgetsBinding.instance.addPostFrameCallback((_) => _popup(fresh));
    }
  }

  Future<void> _popup(List<Map<String, dynamic>> fresh) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    final isDark = context.read<AppController>().isDark;
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: ui.TextDirection.rtl,
        child: GlassAlertDialog(
          title: Text(fresh.length == 1 ? 'مبلغ مستني تأكيد الاستلام' : '${fresh.length} مبالغ مستنية تأكيد الاستلام'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              for (final x in fresh) _row(ctx, isDark, x, popup: true),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('بعدين'))],
        ),
      ),
    );
  }

  Future<void> _receive(BuildContext ctx, Map<String, dynamic> x, {bool popup = false}) async {
    final method = await _askCashOrBank(ctx, 'تم استلام ${x['kindAr']}', '${_money(x['amount'])}\n${x['projectName']} · وحدة ${x['unitNo']} · ${x['clientName']}');
    if (method == null) return;
    final r = await _post('/exclusive/payments/${x['id']}/receive', {'paymentMethod': method}, 'اتأكد الاستلام ✅');
    if (ctx.mounted) JphUi.toast(ctx, r);
    if (popup && ctx.mounted && r['success'] == true) Navigator.pop(ctx);
    await _load();
    widget.onChanged?.call();
  }

  Widget _row(BuildContext ctx, bool isDark, Map<String, dynamic> x, {bool popup = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(x['kind'] == 'reservation' ? Icons.bookmark_add_rounded : Icons.handshake_rounded, color: Ar.amber),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['kind'] == 'reservation' ? 'حجز جديد' : 'تعاقد جديد'} — ${x['projectName']} · وحدة ${x['unitNo']}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              Text('${x['clientName']} · ${x['salesName']} · ${_money(x['amount'])}',
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            ]),
          ),
          FilledButton(
            onPressed: () => _receive(ctx, x, popup: popup),
            style: FilledButton.styleFrom(backgroundColor: Ar.green, padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: const Text('تم الاستلام', style: TextStyle(fontWeight: FontWeight.w800)),
          ),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final isDark = context.watch<AppController>().isDark;
    final total = _items.fold<num>(0, (t, x) => t + _n(x['amount']));
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: Glass.panel(isDark, r: 20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.notifications_active_rounded, color: Ar.amber),
            const SizedBox(width: 8),
            Expanded(
              child: Text('مبالغ مبيعات مستنية تأكيد الاستلام (${_items.length}) — ${_money(total)}',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
            ),
          ]),
          if (_into.isNotEmpty) Text('بتدخل $_into', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
          const SizedBox(height: 4),
          for (final x in _items) _row(context, isDark, x),
        ]),
      ),
    );
  }
}

// ==================================================================== عمولات مشروع واحد (كل المشاريع: حصري + تسويق)
class ProjectCommissionsPage extends StatefulWidget {
  final Map<String, dynamic> project; // one of /cash/overview commissions.byProject
  final DateTime? month;
  const ProjectCommissionsPage({super.key, required this.project, this.month});
  @override
  State<ProjectCommissionsPage> createState() => _ProjectCommissionsPageState();
}

class _ProjectCommissionsPageState extends _OverviewPageState<ProjectCommissionsPage> {
  @override
  DateTime? get initialMonth => widget.month;
  @override
  String get title => 'عمولات ${widget.project['name']}';

  @override
  List<Widget> body(bool isDark) {
    final c = _m(o!['commissions']);
    final p = _l(c['byProject']).firstWhere((x) => x['id'] == widget.project['id'], orElse: () => widget.project);
    final units = _l(c['units']).where((u) => u['projectId'] == widget.project['id']).toList();
    return [
      Text(p['kind'] == 'marketing' ? 'مشروع تسويق' : 'مشروع حصري', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.sub(isDark))),
      const SizedBox(height: 10),
      JphUi.statGrid([
        _tile(isDark, 'عمولة مستحقة', p['due'], Icons.workspace_premium_rounded, Ar.amber.shade800),
        _tile(isDark, 'دخلت خزنة العمولات', p['collected'], Icons.savings_rounded, Ar.green),
        _tile(isDark, 'متبقي لم يتم أخذه', p['remaining'], Icons.hourglass_top_rounded, Ar.amber),
        _tile(isDark, 'جاية من أقساط', p['upcoming'], Icons.event_repeat_rounded, Ar.accent),
        if (_n(p['expected']) > 0) _tile(isDark, 'متوقعة من حجوزات', p['expected'], Icons.event_available_rounded, Ar.green),
      ]),
      const SizedBox(height: 16),
      if (units.isEmpty)
        Padding(padding: const EdgeInsets.all(30), child: Text('مفيش وحدات متعاقد عليها لسه', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      for (final u in units)
        GestureDetector(
          onTap: () => pushSide(context, ExclusiveUnitPage(unitId: '${u['id']}')).then((_) => load()),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, _n(u['remaining']) > 0 ? Icons.hourglass_top_rounded : Icons.task_alt_rounded,
                    _n(u['remaining']) > 0 ? Ar.amber : Ar.green),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('وحدة ${u['unitNo']} — ${u['clientName']}', style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text('${u['salesName']}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                  ]),
                ),
                Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
              ]),
              const SizedBox(height: 6),
              _kv(isDark, 'مستحقة', _money(u['due'])),
              _kv(isDark, 'دخلت', _money(u['collected']), color: Ar.green),
              _kv(isDark, 'متبقي', _money(u['remaining']), color: Ar.amber),
              if (_n(u['upcoming']) > 0) _kv(isDark, 'جاية من أقساط', _money(u['upcoming'])),
            ]),
          ),
        ),
    ];
  }
}


// ==================================================================== المطورين (حصري / تسويق)
class DevelopersPage extends StatefulWidget {
  const DevelopersPage({super.key});
  @override
  State<DevelopersPage> createState() => _DevelopersPageState();
}

/// A development company: its name (what the sales team and the projects show, and its reservation forms carry),
/// its owner (the accounts show him beside the company), its picture and its logo (on its documents).
Future<bool> _editDeveloper(BuildContext context, bool isDark, [Map<String, dynamic>? d]) async {
  final name = TextEditingController(text: '${d?['name'] ?? ''}'), owner = TextEditingController(text: '${d?['ownerName'] ?? ''}'),
      phone = TextEditingController(text: '${d?['phone'] ?? ''}'), notes = TextEditingController(text: '${d?['notes'] ?? ''}');
  (String, String)? photo, logo;
  Widget imgPick(String label, IconData icon, bool had, (String, String)? picked, ValueChanged<(String, String)> onPick, StateSetter set) =>
      JphUi.picker(
        isDark: isDark, icon: icon, iconColor: Ar.accent, label: label,
        value: picked != null ? 'اتختارت صورة جديدة ✓' : had ? 'موجودة — دوس للتغيير' : 'اختار صورة',
        onTap: () async {
          final x = await DocLogos.pick(context);
          if (x != null) set(() => onPick(x));
        },
      );
  return _form(context, isDark, d == null ? 'شركة تطوير جديدة' : 'تعديل شركة التطوير', (set) => [
        JphUi.input(isDark: isDark, label: 'اسم شركة التطوير', controller: name, icon: Icons.business_rounded),
        JphUi.input(isDark: isDark, label: 'اسم المالك', controller: owner, icon: Icons.person_rounded),
        JphUi.input(isDark: isDark, label: 'التليفون', controller: phone, icon: Icons.phone_rounded, number: true),
        imgPick('صورة شركة التطوير', Icons.photo_rounded, d?['photoAt'] != null, photo, (x) => photo = x, set),
        imgPick('لوجو الشركة (على مستنداتها: استمارات الحجز والعقود)', Icons.verified_rounded, d?['logoAt'] != null, logo, (x) => logo = x, set),
        JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
      ], () async {
    final body = {'name': name.text.trim(), 'ownerName': owner.text.trim(), 'phone': phone.text.trim(), 'notes': notes.text.trim()};
    final r = d == null ? await _post('/exclusive/developers', body, 'اتضافت شركة التطوير ✅')
        : await _post('/exclusive/developers/${d['id']}', body, 'اتحفظ ✅', method: 'patch');
    if (context.mounted) JphUi.toast(context, r);
    final id = d?['id'] ?? _m(r['developer'])['id'];
    if (r['success'] == true && id != null) {
      if (photo != null && context.mounted) await DocLogos.upload(context, '/exclusive/developers/$id/image/photo', photo!);
      if (logo != null && context.mounted) await DocLogos.upload(context, '/exclusive/developers/$id/image/logo', logo!, ok: 'اتحفظ اللوجو ✅');
    }
    return r['success'] == true;
  });
}

/// a development company's picture (its icon while it has none)
class _DevPhoto extends StatelessWidget {
  final Map<String, dynamic> d;
  final bool isDark;
  final double size;
  const _DevPhoto({required this.d, required this.isDark, this.size = 44});

  @override
  Widget build(BuildContext context) {
    final icon = ClipRRect(borderRadius: BorderRadius.circular(12), child: DefaultPhoto(size: size));
    if (d['photoAt'] == null) return icon;
    return FutureBuilder<Uint8List?>(
      future: DocLogos.developer('${d['id']}', kind: 'photo', at: d['photoAt']),
      builder: (_, s) => s.data == null
          ? icon
          : ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.memory(s.data!, width: size, height: size, fit: BoxFit.cover)),
    );
  }
}

class _DevelopersPageState extends State<DevelopersPage> {
  Map<String, dynamic>? _d;
  String _kind = 'exclusive';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/developers');
    if (mounted) setState(() => _d = r);
  }

  Future<void> _link(bool isDark, Map<String, dynamic> project) async {
    final devs = _l(_d?['developers']);
    final v = await JphUi.sheet<String>(context, isDark, 'مطور «${project['name']}»',
        [for (final d in devs) ('${d['id']}', '${d['name']}', Icons.business_rounded)]);
    if (v == null) return;
    final r = await _post('/exclusive/projects/${project['id']}/developer', {'developerId': v}, 'اتربط المشروع بالمطور ✅');
    if (mounted) JphUi.toast(context, r);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final devs = _l(_d?['developers']);
    final shown = devs.where((d) => _n(_m(d[_kind])['projects']) > 0 ||
        (_n(_m(d['exclusive'])['projects']) == 0 && _n(_m(d['marketing'])['projects']) == 0)).toList();
    final unlinked = _l(_d?['unlinked']).where((p) => p['kind'] == _kind).toList();
    return _Shell(
      title: 'المطورين',
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['success'] != true
              ? Center(child: Text('${_d!['message'] ?? 'مش متاح'}'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                    _btn(isDark, 'إضافة مطور', Icons.add_business_rounded, () async {
                      if (await _editDeveloper(context, isDark)) _load();
                    }),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _KindBar(
                        isDark: isDark,
                        value: _kind,
                        options: const [('exclusive', 'حصري'), ('marketing', 'تسويق')],
                        counts: {
                          'exclusive': devs.where((d) => _n(_m(d['exclusive'])['projects']) > 0).length,
                          'marketing': devs.where((d) => _n(_m(d['marketing'])['projects']) > 0).length,
                        },
                        onChanged: (v) => setState(() => _kind = v),
                      ),
                    ),
                    if (unlinked.isNotEmpty)
                      _section(isDark, 'مشاريع من غير مطور (${unlinked.length})', [
                        for (final p in unlinked)
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.link_off_rounded, color: Ar.amber),
                            title: Text('${p['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                            trailing: TextButton(onPressed: () => _link(isDark, p), child: const Text('اربطه بمطور')),
                          ),
                      ]),
                    if (shown.isEmpty)
                      Padding(padding: const EdgeInsets.all(30), child: Text('مفيش مطورين', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                    for (final d in shown) _card(isDark, d),
                  ]),
                ),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> d) {
    final k = _m(d[_kind]);
    final exclusive = _kind == 'exclusive';
    return GestureDetector(
      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DeveloperPage(id: '${d['id']}', kind: _kind))).then((_) => _load()),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            _DevPhoto(d: d, isDark: isDark),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                if ('${d['ownerName'] ?? ''}'.isNotEmpty)
                  Text('المالك: ${d['ownerName']}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: JphUi.text(isDark))),
                Text('${k['projects']} مشروع${'${d['phone'] ?? ''}'.isNotEmpty ? ' · ${d['phone']}' : ''}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              ]),
            ),
            Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
          ]),
          const SizedBox(height: 10),
          Row(children: exclusive
              ? [
                  Expanded(child: _mini(isDark, 'في الأمانة', k['inTrust'], Ar.accent)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'اتصرفله', k['paid'], Ar.red)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'الصافي له', k['due'], Ar.green)),
                ]
              : [
                  Expanded(child: _mini(isDark, 'عمولة مستحقة', k['commissionDue'], Ar.amber.shade800)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'اتحصّل', k['commissionCollected'], Ar.green)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'متبقي عليه', k['commissionRemaining'], Ar.amber)),
                ]),
        ]),
      ),
    );
  }
}

/// One developer: his accounts (حصري: his money we hold; تسويق: the commission he owes) and every project of his.
class DeveloperPage extends StatefulWidget {
  final String id;
  final String kind;
  const DeveloperPage({super.key, required this.id, this.kind = 'exclusive'});
  @override
  State<DeveloperPage> createState() => _DeveloperPageState();
}

class _DeveloperPageState extends State<DeveloperPage> {
  Map<String, dynamic>? _d;
  late String _kind = widget.kind;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _get('/exclusive/developers/${widget.id}');
    if (mounted) setState(() => _d = r);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final d = _m(_d?['developer']);
    final k = _m(d[_kind]);
    final exclusive = _kind == 'exclusive';
    return _Shell(
      title: d.isEmpty ? 'المطور' : '${d['name']}',
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['success'] != true
              ? Center(child: Text('${_d!['message'] ?? 'مش متاح'}'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                    // the company, its owner (the accounts name him beside it) and its logo for its documents
                    Row(children: [
                      _DevPhoto(d: d, isDark: isDark, size: 56),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text('${d['accountName'] ?? d['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                          Text(d['logoAt'] == null ? 'من غير لوجو للمستندات' : 'لوجو المستندات موجود ✓',
                              style: TextStyle(fontSize: 12.5, color: d['logoAt'] == null ? Ar.amber : Ar.green)),
                        ]),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      Expanded(
                        child: Text('${'${d['phone'] ?? ''}'.isEmpty ? '' : '📞 ${d['phone']}  '}${d['notes'] ?? ''}',
                            style: TextStyle(color: JphUi.sub(isDark), fontWeight: FontWeight.w700)),
                      ),
                      TextButton.icon(
                        onPressed: () async {
                          if (await _editDeveloper(context, isDark, d)) _load();
                        },
                        icon: const Icon(Icons.edit_rounded),
                        label: const Text('تعديل'),
                      ),
                    ]),
                    const SizedBox(height: 6),
                    _KindBar(
                      isDark: isDark,
                      value: _kind,
                      options: const [('exclusive', 'حصري'), ('marketing', 'تسويق')],
                      counts: {'exclusive': _n(_m(d['exclusive'])['projects']).toInt(), 'marketing': _n(_m(d['marketing'])['projects']).toInt()},
                      onChanged: (v) => setState(() => _kind = v),
                    ),
                    const SizedBox(height: 12),
                    JphUi.statGrid(exclusive
                        ? [
                            _tile(isDark, 'اتحصّل (أمانة)', k['collected'], Icons.savings_rounded, Ar.green),
                            _tile(isDark, 'في الأمانة دلوقتي', k['inTrust'], Icons.real_estate_agent_rounded, Ar.accent),
                            _tile(isDark, 'اتصرفله', k['paid'], Icons.outbox_rounded, Ar.red),
                            _tile(isDark, 'الصافي المستحق له', k['due'], Icons.account_balance_rounded, Ar.green),
                            _tile(isDark, 'عمولة اتحوّلت للمكتب', k['commissionMoved'], Icons.workspace_premium_rounded, Ar.amber.shade800),
                            _tile(isDark, 'مبيعات متعاقد عليها', k['sales'], Icons.sell_rounded, Ar.accent),
                          ]
                        : [
                            _tile(isDark, 'مبيعات متعاقد عليها', k['sales'], Icons.sell_rounded, Ar.accent),
                            _tile(isDark, 'عمولة مستحقة', k['commissionDue'], Icons.workspace_premium_rounded, Ar.amber.shade800),
                            _tile(isDark, 'اتحصّل منه', k['commissionCollected'], Icons.savings_rounded, Ar.green),
                            _tile(isDark, 'متبقي عليه', k['commissionRemaining'], Icons.hourglass_top_rounded, Ar.amber),
                            _tile(isDark, 'عمولة متوقعة', k['commissionExpected'], Icons.event_available_rounded, Ar.green),
                          ]),
                    const SizedBox(height: 16),
                    Text('المشاريع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    const SizedBox(height: 8),
                    if (_l(k['list']).isEmpty)
                      Padding(padding: const EdgeInsets.all(24), child: Text('مفيش مشاريع ${exclusive ? 'حصري' : 'تسويق'}',
                          textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                    for (final p in _l(k['list']))
                      GestureDetector(
                        onTap: () => pushSide(context, ExclusiveProjectPage(projectId: '${p['id']}')).then((_) => _load()),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: JphUi.box(isDark),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              JphUi.iconTile(isDark, exclusive ? Icons.apartment_rounded : Icons.storefront_rounded, exclusive ? Ar.accent : Ar.accent),
                              const SizedBox(width: 10),
                              Expanded(child: Text('${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                              Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
                            ]),
                            const SizedBox(height: 8),
                            Row(children: exclusive
                                ? [
                                    Expanded(child: _mini(isDark, 'في الأمانة', p['inTrust'], Ar.accent)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'اتصرفله', p['paid'], Ar.red)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'الصافي له', p['due'], Ar.green)),
                                  ]
                                : [
                                    Expanded(child: _mini(isDark, 'مستحقة', p['commissionDue'], Ar.amber.shade800)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'اتحصّل', p['commissionCollected'], Ar.green)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'متبقي', p['commissionRemaining'], Ar.amber)),
                                  ]),
                          ]),
                        ),
                      ),
                  ]),
                ),
    );
  }
}
