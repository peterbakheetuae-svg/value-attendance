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
    return _Shell(title: 'المشاريع', child: ProjectsList(isDark: app.isDark));
  }
}

class ProjectsList extends StatefulWidget {
  final bool isDark;
  const ProjectsList({super.key, required this.isDark});

  @override
  State<ProjectsList> createState() => _ProjectsListState();
}

class _ProjectsListState extends State<ProjectsList> {
  bool _loading = true, _manage = false, _reserve = false;
  List<Map<String, dynamic>> _items = [];
  String _kind = ''; // '' = المشاريع (الكل)

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
      _manage = r['canManage'] == true;
      _reserve = r['canReserve'] == true;
    });
  }

  Future<void> _add() async {
    final isDark = widget.isDark;
    String kind = _kind.isEmpty ? 'exclusive' : _kind;
    final name = TextEditingController(), owner = TextEditingController(), phone = TextEditingController();
    final total = TextEditingController(text: '5'), contract = TextEditingController(text: '3'), sales = TextEditingController(text: '0.2'),
        manager = TextEditingController(text: '0.1'), inst = TextEditingController(text: '0.5');
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
          if (kind == 'exclusive') ...[
            JphUi.input(isDark: isDark, label: 'اسم مالك العقار', controller: owner, icon: Icons.person_rounded),
            JphUi.input(isDark: isDark, label: 'تليفون المالك', controller: phone, icon: Icons.phone_rounded, number: true),
          ],
          JphUi.input(isDark: isDark, label: 'إجمالي العمولة ٪', controller: total, number: true, icon: Icons.percent_rounded),
          if (kind == 'exclusive')
            JphUi.input(isDark: isDark, label: 'منها عند التعاقد ٪', controller: contract, number: true, icon: Icons.handshake_rounded),
          JphUi.input(isDark: isDark, label: 'السيلز ٪', controller: sales, number: true, icon: Icons.person_outline_rounded),
          JphUi.input(isDark: isDark, label: 'مدير المبيعات ٪', controller: manager, number: true, icon: Icons.groups_rounded),
          if (kind == 'exclusive')
            JphUi.input(isDark: isDark, label: 'نسبة كل قسط ٪ (افتراضي — تتغير لكل وحدة)', controller: inst, number: true, icon: Icons.event_repeat_rounded),
          AnimatedBuilder(
            animation: Listenable.merge([total, sales, manager]),
            builder: (_, __) => Text('نصيب المكتب: ${JphUi.pct(office())}',
                style: TextStyle(fontWeight: FontWeight.w800, color: Colors.teal.shade600)),
          ),
        ], () async {
      final Map<String, dynamic> r;
      if (kind == 'exclusive') {
        r = await _post('/exclusive/projects', {
          'name': name.text.trim(), 'ownerName': owner.text.trim(), 'ownerPhone': phone.text.trim(),
          'totalPct': num.tryParse(total.text), 'contractPct': num.tryParse(contract.text), 'salesPct': num.tryParse(sales.text),
          'managerPct': num.tryParse(manager.text), 'installmentPct': num.tryParse(inst.text),
        }, 'اتضاف المشروع ✅');
      } else {
        final t = num.tryParse(total.text) ?? 0, sp = num.tryParse(sales.text) ?? 0, mp = num.tryParse(manager.text) ?? 0;
        r = await _post('/commissions/projects', {
          'name': name.text.trim(), 'totalPct': t, 'salesPct': sp, 'managerPct': mp,
          'companyPct': num.parse((t - sp - mp).toStringAsFixed(4)),
        }, 'اتضاف المشروع ✅');
      }
      if (mounted) JphUi.toast(context, r);
      return r['success'] == true;
    });
    if (ok) _load();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = widget.isDark;
    final shown = _items.where((p) => _kind.isEmpty || p['kind'] == _kind).toList();
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
        if (_manage) _btn(isDark, 'إضافة مشروع', Icons.add_rounded, _add),
        // the filter bar under «إضافة مشروع»
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: _KindBar(
            isDark: isDark,
            value: _kind,
            options: const [('', 'المشاريع'), ('exclusive', 'حصري'), ('marketing', 'تسويق')],
            counts: {'': _items.length, 'exclusive': _items.where((p) => p['kind'] == 'exclusive').length,
              'marketing': _items.where((p) => p['kind'] == 'marketing').length},
            onChanged: (v) => setState(() => _kind = v),
          ),
        ),
        if (_reserve && shown.isNotEmpty)
          _btn(isDark, 'حجز وحدة', Icons.bookmark_add_rounded, () => reserveUnit(context, isDark, shown, then: _load), color: Colors.teal),
        if (_loading) const Padding(padding: EdgeInsets.all(30), child: Center(child: CircularProgressIndicator())),
        if (!_loading && shown.isEmpty)
          Padding(padding: const EdgeInsets.all(30), child: Text('مفيش مشاريع', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
        for (final p in shown) _card(isDark, p),
      ]),
    );
  }

  Widget _card(bool isDark, Map<String, dynamic> p) {
    final st = _m(p['stats']);
    final u = _m(st['units']), cm = _m(st['commission']), ow = _m(st['owner']);
    final marketing = p['kind'] == 'marketing';
    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveProjectPage(projectId: '${p['id']}')));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: JphUi.box(isDark),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            JphUi.iconTile(isDark, marketing ? Icons.storefront_rounded : Icons.apartment_rounded, marketing ? Colors.deepPurple : Colors.indigo),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p['name']}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                if (!marketing && p['ownerName'] != null)
                  Text('المالك: ${p['ownerName']}', style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
              ]),
            ),
            _pill(marketing ? 'تسويق' : 'حصري', marketing ? Colors.deepPurple : Colors.indigo),
            if (p['status'] != 'active') ...[const SizedBox(width: 4), _pill(p['status'] == 'paused' ? 'متوقف' : 'مقفول', Colors.orange)],
            Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            if (p['totalPct'] != null) _pill('عمولة ${JphUi.pct(p['totalPct'])}', Colors.indigo),
            if (!marketing && p['contractPct'] != null) _pill('عند التعاقد ${JphUi.pct(p['contractPct'])}', Colors.teal),
            if (!marketing && p['installmentPct'] != null) _pill('القسط ${JphUi.pct(p['installmentPct'])}', Colors.purple),
            _pill('سيلز ${JphUi.pct(p['salesPct'])}${p['managerPct'] != null ? ' · مدير ${JphUi.pct(p['managerPct'])}' : ''}', Colors.blueGrey),
          ]),
          if (st.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, runSpacing: 6, children: [
              _pill('محجوز ${u['reserved']}', _statusColor('reserved')),
              _pill('متعاقد ${u['contracted']}', _statusColor('contracted')),
              _pill('مكتمل ${u['completed']}', _statusColor('completed')),
              _pill('ملغي ${u['cancelled']}', _statusColor('cancelled')),
            ]),
            const SizedBox(height: 8),
            if (marketing) ...[
              _kv(isDark, 'مبيعات متعاقد عليها', _money(st['sales'])),
              _kv(isDark, 'نصيب المكتب من العمولة', _money(cm['office']), color: Colors.teal),
            ] else ...[
              _kv(isDark, 'في الأمانة', _money(ow['inTrust'])),
              _kv(isDark, 'المستحق للمالك', _money(ow['due'])),
              _kv(isDark, 'عمولة مستنية التحويل', _money(cm['pending']), color: Colors.orange),
            ],
          ],
        ]),
      ),
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
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.08) : Colors.white.withOpacity(0.55),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: isDark ? Colors.white12 : Colors.black.withOpacity(0.06)),
      ),
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
  List<Map<String, dynamic>> _units = [], _projects = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await Future.wait([
      _get('/exclusive/units', {'stage': _stage, if (_kind.isNotEmpty) 'kind': _kind}),
      if (_projects.isEmpty) _get('/exclusive/projects', {'kind': 'all'}),
    ]);
    if (!mounted) return;
    setState(() {
      _loading = false;
      _units = _l(r[0]['units']);
      if (r.length > 1) {
        _projects = _l(r[1]['projects']);
        _reserve = r[1]['canReserve'] == true;
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
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            for (final f in const [('', 'كل المشاريع'), ('exclusive', 'حصري'), ('marketing', 'تسويق')])
              Padding(
                padding: const EdgeInsetsDirectional.only(end: 6),
                child: ChoiceChip(label: Text(f.$2), selected: _kind == f.$1, onSelected: (_) {
                  setState(() => _kind = f.$1);
                  _load();
                }),
              ),
          ]),
        ),
        const SizedBox(height: 10),
        if (_stage == 'reservation' && _reserve && _projects.isNotEmpty)
          _btn(isDark, 'حجز وحدة', Icons.bookmark_add_rounded,
              () => reserveUnit(context, isDark, _projects.where((p) => _kind.isEmpty || p['kind'] == _kind).toList(), then: _load), color: Colors.teal),
        if (_stage == 'contract')
          OutlinedButton.icon(
            onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const _DirectSalePage())).then((_) => _load()),
            icon: const Icon(Icons.post_add_rounded),
            label: const Text('تسجيل بيعة مباشرة (من غير حجز) + طلب عمولة', style: TextStyle(fontWeight: FontWeight.w800)),
            style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 50),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          ),
        if (_stage == 'reservation' && waiting > 0)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('$waiting حجز مستني إجراء', style: const TextStyle(color: Colors.deepOrange, fontWeight: FontWeight.w800)),
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

  Widget _unitCard(bool isDark, Map<String, dynamic> x) {
    final money = _m(x['money']);
    final st = '${x['status']}';
    final marketing = x['projectKind'] == 'marketing';
    final inst = _m(x['installments']);
    return GestureDetector(
      onTap: () async {
        await Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveUnitPage(unitId: '${x['id']}')));
        _load();
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: JphUi.box(isDark),
        child: Row(children: [
          JphUi.iconTile(isDark, marketing ? Icons.storefront_rounded : Icons.home_work_rounded, _statusColor(st)),
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
              Text('${_money(x['unitPrice'])} · اتحصّل ${_money(money['collected'])}'
                  '${_n(inst['total']) > 0 ? ' · أقساط ${inst['paid']}/${inst['total']}' : ''}',
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// The old direct sale (a marketing unit sold without a reservation) + its commission request.
class _DirectSalePage extends StatelessWidget {
  const _DirectSalePage();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    return _Shell(title: 'تسجيل بيعة مباشرة', child: SalesTab(isDark: app.isDark));
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
                        _kv(isDark, 'اتصرف للمالك', _money(o['paid']), color: Colors.green),
                        const Divider(),
                        _kv(isDark, 'في الأمانة دلوقتي', _money(o['inTrust'])),
                        _kv(isDark, 'الصافي المستحق للمالك', _money(o['due']), color: Colors.teal),
                        const SizedBox(height: 6),
                        for (final p in _l(o['projects']))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(Icons.apartment_rounded, color: Colors.indigo),
                            title: Text('${p['name']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                            subtitle: Text('مستحق ${_money(p['due'])}', style: TextStyle(color: JphUi.sub(isDark))),
                            trailing: Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
                            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveProjectPage(projectId: '${p['id']}')))
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

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    final q = _q.text.trim();
    final clients = _l(_d?['clients']).where((c) => q.isEmpty || '${c['name']}'.contains(q) || '${c['phone'] ?? ''}'.contains(q)).toList();
    return _Shell(
      title: 'العملاء',
      child: _d == null
          ? const Center(child: CircularProgressIndicator())
          : _d!['success'] != true
              ? Center(child: Text('${_d!['message'] ?? 'مش متاح'}'))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                    JphUi.input(isDark: isDark, label: 'دوّر باسم العميل أو تليفونه', controller: _q, icon: Icons.search_rounded, onChanged: (_) => setState(() {})),
                    const SizedBox(height: 12),
                    if (clients.isEmpty)
                      Padding(padding: const EdgeInsets.all(30), child: Text('مفيش عملاء', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                    for (final c in clients)
                      _section(isDark, '${c['name']}', [
                        if ('${c['phone'] ?? ''}'.isNotEmpty) _kv(isDark, 'التليفون', '${c['phone']}'),
                        _kv(isDark, 'إجمالي الوحدات', _money(c['total'])),
                        _kv(isDark, 'دفع', _money(c['paid']), color: Colors.green),
                        _kv(isDark, 'الباقي', _money(c['remaining']), color: Colors.orange),
                        const SizedBox(height: 4),
                        for (final u in _l(c['units']))
                          ListTile(
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(u['projectKind'] == 'marketing' ? Icons.storefront_rounded : Icons.home_work_rounded,
                                color: _statusColor('${u['status']}')),
                            title: Text('${u['projectName']} — وحدة ${u['unitNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                            subtitle: Text('${u['statusAr']} · ${_money(u['price'])} · دفع ${_money(u['paid'])}', style: TextStyle(color: JphUi.sub(isDark))),
                            trailing: u['source'] == 'unit' ? Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)) : null,
                            onTap: u['source'] == 'unit'
                                ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveUnitPage(unitId: '${u['id']}'))).then((_) => _load())
                                : null,
                          ),
                      ]),
                  ]),
                ),
    );
  }
}
