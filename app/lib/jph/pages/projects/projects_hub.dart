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
  bool _loading = true, _manage = false;
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
    });
  }

  Future<void> _add() async {
    final isDark = widget.isDark;
    String kind = _kind.isEmpty ? 'exclusive' : _kind;
    final name = TextEditingController(), owner = TextEditingController(), phone = TextEditingController();
    // المطور: an existing one or a new name
    final devs = _l((await _get('/exclusive/developers'))['developers']);
    Map<String, dynamic>? dev;
    if (!mounted) return;
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
          Text(kind == 'exclusive' ? 'المطور (مالك المشروع)' : 'المطور', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
          if (devs.isNotEmpty)
            Wrap(spacing: 6, runSpacing: 6, children: [
              for (final d in devs)
                ChoiceChip(label: Text('${d['name']}'), selected: dev?['id'] == d['id'], onSelected: (_) => set(() {
                  dev = dev?['id'] == d['id'] ? null : d;
                  if (dev != null) owner.clear();
                })),
            ]),
          if (dev == null) ...[
            JphUi.input(isDark: isDark, label: devs.isEmpty ? 'اسم المطور' : 'أو مطور جديد — اسمه', controller: owner, icon: Icons.business_rounded),
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
                style: TextStyle(fontWeight: FontWeight.w800, color: Colors.teal.shade600)),
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
        r = await _post('/commissions/projects', {
          'name': name.text.trim(), 'totalPct': t, 'salesPct': sp, 'managerPct': mp,
          if (dev != null) 'developerId': dev!['id'] else ...{'developerName': owner.text.trim(), 'developerPhone': phone.text.trim()},
          'companyPct': num.parse((t - sp - mp).toStringAsFixed(4)), 'marketingPct': num.tryParse(mkPct.text) ?? 0,
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
                if (p['developerName'] != null || (!marketing && p['ownerName'] != null))
                  Text('المطور: ${p['developerName'] ?? p['ownerName']}', style: TextStyle(fontSize: 13, color: JphUi.sub(isDark))),
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
            if (_n(p['marketingPct']) > 0) _pill('شركات التسويق ${JphUi.pct(p['marketingPct'])}', Colors.deepPurple),
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
                  const Icon(Icons.hourglass_top_rounded, color: Colors.orange),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${x['kindAr']} — ${x['projectName']} · وحدة ${x['unitNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
                      Text('${x['clientName']} · ${x['salesName']} · ${x['methodAr']}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(_money(x['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    if (_canReceive)
                      TextButton(onPressed: () => _receive(isDark, x), child: const Text('تم الاستلام', style: TextStyle(fontWeight: FontWeight.w900))),
                  ]),
                ]),
              ),
          ]),
        ],
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
        if (_reserve && _projects.isNotEmpty)
          _btn(isDark, _stage == 'reservation' ? 'حجز جديد' : 'تعاقد جديد', _stage == 'reservation' ? Icons.bookmark_add_rounded : Icons.handshake_rounded,
              () => newUnit(context, isDark, _projects.where((p) => _kind.isEmpty || p['kind'] == _kind).toList(),
                  contract: _stage == 'contract', then: _load),
              color: _stage == 'reservation' ? Colors.teal : JphUi.primary(isDark)),
        if (_stage == 'reservation')
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text('الحجز بيتحوّل لتعاقد من صفحة الوحدة (دوس على الحجز).', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
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

  Future<void> _receive(bool isDark, Map<String, dynamic> x) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassAlertDialog(
        title: Text('تم استلام ${x['kindAr']}'),
        content: Text('${_money(x['amount'])} — ${x['methodAr']}\n${x['projectName']} · وحدة ${x['unitNo']} · ${x['clientName']}\nهيدخل $_into',
            textAlign: TextAlign.center),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('لسه')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('تم الاستلام')),
        ],
      ),
    );
    if (yes != true) return;
    final r = await _post('/exclusive/payments/${x['id']}/receive', {}, 'اتأكد الاستلام ✅');
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
              Text('${_money(x['unitPrice'])}${marketing ? '' : ' · اتحصّل ${_money(money['collected'])}'}'
                  '${_n(inst['total']) > 0 ? ' · أقساط ${inst['paid']}/${inst['total']}' : ''}',
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              if (_m(x['commission']).isNotEmpty) ...[
                const SizedBox(height: 4),
                Wrap(spacing: 6, children: [
                  if (_n(_m(x['commission'])['potential']) > 0) _pill('عمولة محتملة ${_money(_m(x['commission'])['potential'])}', Colors.indigo),
                  if (_n(_m(x['commission'])['receivable']) > 0) _pill('واجبة التحصيل ${_money(_m(x['commission'])['receivable'])}', Colors.orange),
                  if (st != 'reserved' && _n(_m(x['commission'])['receivable']) == 0 && _n(_m(x['commission'])['collected']) > 0)
                    _pill('العمولة اتحصّلت', Colors.green),
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

  Future<void> _pick(BuildContext context) async {
    final now = DateTime.now();
    final months = [for (var i = -24; i <= 12; i++) DateTime(now.year, now.month + i)].reversed.toList();
    final v = await JphUi.sheet<String>(context, isDark, 'اختار الشهر', [
      for (final m in months) ('${m.year}-${m.month}', monthLabel(m), m.year == now.year && m.month == now.month ? Icons.today_rounded : Icons.calendar_month_rounded),
    ], selected: month == null ? null : '${month!.year}-${month!.month}');
    if (v == null) return;
    final p = v.split('-');
    onChanged(DateTime(int.parse(p[0]), int.parse(p[1])));
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(children: [
          ChoiceChip(
            label: const Text('كل الشهور', style: TextStyle(fontWeight: FontWeight.w800)),
            avatar: const Icon(Icons.all_inclusive_rounded, size: 18),
            selected: month == null,
            onSelected: (_) => onChanged(null),
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: Text(month == null ? 'اختار شهر' : monthLabel(month), style: const TextStyle(fontWeight: FontWeight.w800)),
            avatar: const Icon(Icons.calendar_month_rounded, size: 18),
            selected: month != null,
            onSelected: (_) => _pick(context),
          ),
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
        FittedBox(fit: BoxFit.scaleDown, child: Text(_money(v), style: TextStyle(fontWeight: FontWeight.w900, color: color))),
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

  Widget filter(bool isDark) => MonthFilterBar(isDark: isDark, month: month, onChanged: (m) {
        setState(() {
          month = m;
          o = null;
        });
        load();
      });

  String get title;
  List<Widget> body(bool isDark);

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return _Shell(
      title: title,
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
        _tile(isDark, 'إجمالي الأمانات', box['total'], Icons.real_estate_agent_rounded, Colors.purple),
        _tile(isDark, 'من الحجوزات', sum('reservation'), Icons.bookmark_rounded, Colors.teal),
        _tile(isDark, 'من التعاقد', sum('contract'), Icons.handshake_rounded, Colors.indigo),
        _tile(isDark, 'من الأقساط', sum('installments'), Icons.event_repeat_rounded, Colors.blue),
        _tile(isDark, 'اتصرف للملاك', sum('paidToOwner'), Icons.outbox_rounded, Colors.red),
        _tile(isDark, 'الصافي للملاك', sum('ownerDue'), Icons.account_balance_rounded, Colors.green),
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
              JphUi.iconTile(isDark, Icons.apartment_rounded, Colors.purple),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                  Text('المالك: ${p['ownerName'] ?? '—'}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(_money(p['inTrust']), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: Colors.purple)),
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
        _tile(isDark, 'موجود أمانات (دلوقتي)', p['inTrust'], Icons.real_estate_agent_rounded, Colors.purple),
        _tile(isDark, 'من الحجز', p['reservation'], Icons.bookmark_rounded, Colors.teal),
        _tile(isDark, 'من التعاقد', p['contract'], Icons.handshake_rounded, Colors.indigo),
        _tile(isDark, 'من الأقساط', p['installments'], Icons.event_repeat_rounded, Colors.blue),
        _tile(isDark, 'للمالك / المطور (صافي دلوقتي)', p['ownerDue'], Icons.account_balance_rounded, Colors.green),
        _tile(isDark, 'اتصرف للمالك / المطور', p['paidToOwner'], Icons.outbox_rounded, Colors.red),
        _tile(isDark, 'عمولة اتحوّلت للمكتب', p['commissionMoved'], Icons.workspace_premium_rounded, Colors.amber.shade800),
        if (_n(p['refunded']) > 0) _tile(isDark, 'اترد لعملاء لغوا', p['refunded'], Icons.undo_rounded, Colors.orange),
        if (_n(p['pendingPayout']) > 0) _tile(isDark, 'صرف مستني الموافقة', p['pendingPayout'], Icons.hourglass_top_rounded, Colors.orange),
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
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveUnitPage(unitId: '${u['id']}'))).then((_) => load()),
            ),
        ]),
      _section(isDark, 'كشف حساب المالك${month == null ? '' : ' — ${monthLabel(month)}'}', [
        if (statement.isEmpty) Text('مفيش حركات', style: TextStyle(color: JphUi.sub(isDark))),
        for (final s in statement)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(children: [
              Icon(s['dir'] == 'in' ? Icons.south_west_rounded : Icons.north_east_rounded, color: s['dir'] == 'in' ? Colors.green : Colors.red, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${s['typeAr']}${s['unitNo'] != null ? ' — وحدة ${s['unitNo']}' : ''} · ${_date(s['at'])}',
                    style: TextStyle(color: JphUi.text(isDark))),
              ),
              Text(_money(s['amount']), style: TextStyle(fontWeight: FontWeight.w900, color: s['dir'] == 'in' ? Colors.green : Colors.red)),
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
        _tile(isDark, 'عمولة مستحقة', c['due'], Icons.workspace_premium_rounded, Colors.amber.shade800),
        _tile(isDark, 'دخلت خزنة العمولات', c['collected'], Icons.savings_rounded, Colors.green),
        _tile(isDark, 'متبقي لم يتم أخذه', c['remaining'], Icons.hourglass_top_rounded, Colors.orange),
        _tile(isDark, 'جاية من أقساط لسه', c['upcoming'], Icons.event_repeat_rounded, Colors.indigo),
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
                    p['kind'] == 'marketing' ? Colors.deepPurple : Colors.indigo),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    Text(p['kind'] == 'marketing' ? 'تسويق' : 'حصري', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
                  ]),
                ),
                Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                  Text(_money(p['remaining']), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: Colors.orange)),
                  Text('متبقي', style: TextStyle(fontSize: 12, color: JphUi.sub(isDark))),
                ]),
                Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
              ]),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: _mini(isDark, 'مستحقة', p['due'], Colors.amber.shade800)),
                const SizedBox(width: 6),
                Expanded(child: _mini(isDark, 'دخلت', p['collected'], Colors.green)),
                const SizedBox(width: 6),
                Expanded(child: _mini(isDark, 'متوقعة', p['expected'], Colors.teal)),
              ]),
            ]),
          ),
        ),
      if (_n(_m(c['legacy'])['due']) > 0)
        _section(isDark, 'عمولات صفقات قديمة (من غير وحدة)', [
          _kv(isDark, 'مستحقة', _money(_m(c['legacy'])['due'])),
          _kv(isDark, 'دخلت', _money(_m(c['legacy'])['collected']), color: Colors.green),
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
        _tile(isDark, 'إجمالي المتوقع', e['total'], Icons.event_available_rounded, Colors.indigo),
        for (final m in months.take(5)) _tile(isDark, _ym('${m['month']}'), m['amount'], Icons.calendar_month_rounded, Colors.teal),
      ]),
      const SizedBox(height: 16),
      if (months.isEmpty)
        Padding(padding: const EdgeInsets.all(30), child: Text('مفيش حجوزات مفتوحة', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      for (final m in months)
        _section(isDark, '${_ym('${m['month']}')} — ${_money(m['amount'])}', [
          for (final u in _l(m['units']))
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.bookmark_rounded, color: Colors.indigo),
              title: Text('${u['projectName']} — وحدة ${u['unitNo']}', style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              subtitle: Text('${u['clientName']} · ${u['salesName']}${u['expectedContractDate'] != null ? ' · تعاقد متوقع ${_date(u['expectedContractDate'])}' : ''}',
                  style: TextStyle(color: JphUi.sub(isDark))),
              trailing: Text(_money(u['amount']), style: const TextStyle(fontWeight: FontWeight.w900, color: Colors.indigo)),
              onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveUnitPage(unitId: '${u['id']}'))).then((_) => load()),
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
    final r = await _post('/exclusive/payments/${x['id']}/receive', {}, 'اتأكد الاستلام ✅');
    if (ctx.mounted) JphUi.toast(ctx, r);
    if (popup && ctx.mounted && r['success'] == true) Navigator.pop(ctx);
    await _load();
    widget.onChanged?.call();
  }

  Widget _row(BuildContext ctx, bool isDark, Map<String, dynamic> x, {bool popup = false}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Icon(x['kind'] == 'reservation' ? Icons.bookmark_add_rounded : Icons.handshake_rounded, color: Colors.orange),
          const SizedBox(width: 8),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${x['kind'] == 'reservation' ? 'حجز جديد' : 'تعاقد جديد'} — ${x['projectName']} · وحدة ${x['unitNo']}',
                  style: TextStyle(fontWeight: FontWeight.w800, color: JphUi.text(isDark))),
              Text('${x['clientName']} · ${x['salesName']} · ${x['methodAr']} · ${_money(x['amount'])}',
                  style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
            ]),
          ),
          FilledButton(
            onPressed: () => _receive(ctx, x, popup: popup),
            style: FilledButton.styleFrom(backgroundColor: Colors.green, padding: const EdgeInsets.symmetric(horizontal: 12)),
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
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.55),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.orange.withOpacity(0.6), width: 1.4),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            const Icon(Icons.notifications_active_rounded, color: Colors.orange),
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
        _tile(isDark, 'عمولة مستحقة', p['due'], Icons.workspace_premium_rounded, Colors.amber.shade800),
        _tile(isDark, 'دخلت خزنة العمولات', p['collected'], Icons.savings_rounded, Colors.green),
        _tile(isDark, 'متبقي لم يتم أخذه', p['remaining'], Icons.hourglass_top_rounded, Colors.orange),
        _tile(isDark, 'جاية من أقساط', p['upcoming'], Icons.event_repeat_rounded, Colors.indigo),
        if (_n(p['expected']) > 0) _tile(isDark, 'متوقعة من حجوزات', p['expected'], Icons.event_available_rounded, Colors.teal),
      ]),
      const SizedBox(height: 16),
      if (units.isEmpty)
        Padding(padding: const EdgeInsets.all(30), child: Text('مفيش وحدات متعاقد عليها لسه', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
      for (final u in units)
        GestureDetector(
          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveUnitPage(unitId: '${u['id']}'))).then((_) => load()),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(14),
            decoration: JphUi.box(isDark),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [
                JphUi.iconTile(isDark, _n(u['remaining']) > 0 ? Icons.hourglass_top_rounded : Icons.task_alt_rounded,
                    _n(u['remaining']) > 0 ? Colors.orange : Colors.green),
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
              _kv(isDark, 'دخلت', _money(u['collected']), color: Colors.green),
              _kv(isDark, 'متبقي', _money(u['remaining']), color: Colors.orange),
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

Future<bool> _editDeveloper(BuildContext context, bool isDark, [Map<String, dynamic>? d]) async {
  final name = TextEditingController(text: '${d?['name'] ?? ''}'), phone = TextEditingController(text: '${d?['phone'] ?? ''}'),
      notes = TextEditingController(text: '${d?['notes'] ?? ''}');
  return _form(context, isDark, d == null ? 'مطور جديد' : 'تعديل المطور', (set) => [
        JphUi.input(isDark: isDark, label: 'اسم المطور', controller: name, icon: Icons.business_rounded),
        JphUi.input(isDark: isDark, label: 'التليفون', controller: phone, icon: Icons.phone_rounded, number: true),
        JphUi.input(isDark: isDark, label: 'ملاحظات', controller: notes, icon: Icons.notes_rounded),
      ], () async {
    final body = {'name': name.text.trim(), 'phone': phone.text.trim(), 'notes': notes.text.trim()};
    final r = d == null ? await _post('/exclusive/developers', body, 'اتضاف المطور ✅')
        : await _post('/exclusive/developers/${d['id']}', body, 'اتحفظ ✅', method: 'patch');
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  });
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
                            leading: const Icon(Icons.link_off_rounded, color: Colors.orange),
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
            JphUi.iconTile(isDark, Icons.business_rounded, exclusive ? Colors.indigo : Colors.deepPurple),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${d['name']}', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                Text('${k['projects']} مشروع${'${d['phone'] ?? ''}'.isNotEmpty ? ' · ${d['phone']}' : ''}', style: TextStyle(fontSize: 12.5, color: JphUi.sub(isDark))),
              ]),
            ),
            Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
          ]),
          const SizedBox(height: 10),
          Row(children: exclusive
              ? [
                  Expanded(child: _mini(isDark, 'في الأمانة', k['inTrust'], Colors.purple)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'اتصرفله', k['paid'], Colors.red)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'الصافي له', k['due'], Colors.green)),
                ]
              : [
                  Expanded(child: _mini(isDark, 'عمولة مستحقة', k['commissionDue'], Colors.amber.shade800)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'اتحصّل', k['commissionCollected'], Colors.green)),
                  const SizedBox(width: 6),
                  Expanded(child: _mini(isDark, 'متبقي عليه', k['commissionRemaining'], Colors.orange)),
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
                            _tile(isDark, 'اتحصّل (أمانة)', k['collected'], Icons.savings_rounded, Colors.teal),
                            _tile(isDark, 'في الأمانة دلوقتي', k['inTrust'], Icons.real_estate_agent_rounded, Colors.purple),
                            _tile(isDark, 'اتصرفله', k['paid'], Icons.outbox_rounded, Colors.red),
                            _tile(isDark, 'الصافي المستحق له', k['due'], Icons.account_balance_rounded, Colors.green),
                            _tile(isDark, 'عمولة اتحوّلت للمكتب', k['commissionMoved'], Icons.workspace_premium_rounded, Colors.amber.shade800),
                            _tile(isDark, 'مبيعات متعاقد عليها', k['sales'], Icons.sell_rounded, Colors.indigo),
                          ]
                        : [
                            _tile(isDark, 'مبيعات متعاقد عليها', k['sales'], Icons.sell_rounded, Colors.indigo),
                            _tile(isDark, 'عمولة مستحقة', k['commissionDue'], Icons.workspace_premium_rounded, Colors.amber.shade800),
                            _tile(isDark, 'اتحصّل منه', k['commissionCollected'], Icons.savings_rounded, Colors.green),
                            _tile(isDark, 'متبقي عليه', k['commissionRemaining'], Icons.hourglass_top_rounded, Colors.orange),
                            _tile(isDark, 'عمولة متوقعة', k['commissionExpected'], Icons.event_available_rounded, Colors.teal),
                          ]),
                    const SizedBox(height: 16),
                    Text('المشاريع', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w900, color: JphUi.text(isDark))),
                    const SizedBox(height: 8),
                    if (_l(k['list']).isEmpty)
                      Padding(padding: const EdgeInsets.all(24), child: Text('مفيش مشاريع ${exclusive ? 'حصري' : 'تسويق'}',
                          textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))),
                    for (final p in _l(k['list']))
                      GestureDetector(
                        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ExclusiveProjectPage(projectId: '${p['id']}'))).then((_) => _load()),
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 10),
                          padding: const EdgeInsets.all(14),
                          decoration: JphUi.box(isDark),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Row(children: [
                              JphUi.iconTile(isDark, exclusive ? Icons.apartment_rounded : Icons.storefront_rounded, exclusive ? Colors.indigo : Colors.deepPurple),
                              const SizedBox(width: 10),
                              Expanded(child: Text('${p['name']}', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: JphUi.text(isDark)))),
                              Icon(Icons.chevron_left_rounded, color: JphUi.sub(isDark)),
                            ]),
                            const SizedBox(height: 8),
                            Row(children: exclusive
                                ? [
                                    Expanded(child: _mini(isDark, 'في الأمانة', p['inTrust'], Colors.purple)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'اتصرفله', p['paid'], Colors.red)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'الصافي له', p['due'], Colors.green)),
                                  ]
                                : [
                                    Expanded(child: _mini(isDark, 'مستحقة', p['commissionDue'], Colors.amber.shade800)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'اتحصّل', p['commissionCollected'], Colors.green)),
                                    const SizedBox(width: 6),
                                    Expanded(child: _mini(isDark, 'متبقي', p['commissionRemaining'], Colors.orange)),
                                  ]),
                          ]),
                        ),
                      ),
                  ]),
                ),
    );
  }
}
