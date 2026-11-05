import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../services/api_service.dart';

/// Company information & office location — same glass UI as the original company screen,
/// with the office geofence drawn on an OpenStreetMap map. The offices here drive geofencing.
class CompanyInfoPage extends StatefulWidget {
  const CompanyInfoPage({super.key});

  @override
  State<CompanyInfoPage> createState() => _CompanyInfoPageState();
}

class _CompanyInfoPageState extends State<CompanyInfoPage> {
  Map<String, dynamic> _company = {};
  List<Map<String, dynamic>> _offices = [];
  bool _canEdit = false;
  bool _loading = true;
  bool _error = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    final res = await ApiService.post({'action': 'get_company_info'});
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (res['success'] == true) {
        _company = ((res['data'] as Map?) ?? {}).cast<String, dynamic>();
        _offices = ((res['offices'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
        _canEdit = res['canEdit'] == true;
      } else {
        _error = true;
        _errorMessage = res['message']?.toString() ?? '';
      }
    });
  }

  void _snack(Map<String, dynamic> r) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('${r['message'] ?? ''}'),
      backgroundColor: r['success'] == true ? Colors.green : Colors.red,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            AppLocalizations.of(context, 'company_info'),
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.of(context).pop()),
          actions: [
            if (_canEdit) IconButton(icon: const Icon(Icons.edit_outlined), onPressed: _editCompany),
            IconButton(icon: const Icon(Icons.refresh), onPressed: _loadData),
          ],
        ),
        // one office only: add it once, then edit it
        floatingActionButton: _canEdit
            ? FloatingActionButton.extended(
                backgroundColor: AppColors.primary,
                onPressed: () => _editOffice(_offices.isEmpty ? null : _offices.first),
                icon: Icon(_offices.isEmpty ? Icons.add_location_alt_rounded : Icons.edit_location_alt_rounded, color: Colors.white),
                label: Text(_offices.isEmpty ? 'تحديد موقع المكتب' : 'تعديل موقع المكتب', style: const TextStyle(color: Colors.white)),
              )
            : null,
        body: _buildBody(),
      ),
    );
  }

  Widget _row(String title, String value, {IconData? icon}) {
    final isDark = Provider.of<AppController>(context).isDark;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (icon != null) ...[Icon(icon, size: 18, color: AppColors.primary), const SizedBox(width: 8)],
        Text(title, style: TextStyle(color: isDark ? AppColors.onSurfaceVariantDark : Colors.black54)),
        const SizedBox(width: 12),
        Expanded(
          child: Text(value.isEmpty ? '-' : value, textAlign: TextAlign.end,
              style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? AppColors.onSurfaceDark : Colors.black)),
        ),
      ]),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(AppLocalizations.of(context, 'loading_data'), style: TextStyle(color: AppColors.onSurfaceVariantLight)),
        ]),
      );
    }
    if (_error) {
      return Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.error_outline, size: 48, color: AppColors.error),
          const SizedBox(height: 12),
          Text(_errorMessage.isNotEmpty ? _errorMessage : AppLocalizations.of(context, 'error_occurred'),
              textAlign: TextAlign.center, style: TextStyle(color: AppColors.onSurfaceVariantLight)),
        ]),
      );
    }

    final active = _offices.where((o) => o['active'] != false).toList();
    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
        children: [
          GlassCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(
                  width: 48, height: 48,
                  decoration: BoxDecoration(color: AppColors.primary.withOpacity(0.1), borderRadius: BorderRadius.circular(14)),
                  child: const Icon(Icons.business, color: AppColors.primary, size: 26),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text('${_company['name'] ?? AppLocalizations.of(context, 'company')}',
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                ),
              ]),
              if ('${_company['description'] ?? ''}'.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text('${_company['description']}', style: const TextStyle(height: 1.5)),
              ],
              const SizedBox(height: 12),
              _row('العنوان', '${_company['address'] ?? ''}', icon: Icons.place_outlined),
              _row('التليفون', '${_company['phone'] ?? ''}', icon: Icons.phone_outlined),
              _row('البريد', '${_company['email'] ?? ''}', icon: Icons.email_outlined),
              _row('العملة', '${_company['currency'] ?? ''}', icon: Icons.payments_outlined),
              if (_company['updatedByName'] != null)
                _row('آخر تعديل', '${_company['updatedByName']} — ${_date(_company['updatedAt'])}', icon: Icons.history_rounded),
            ]),
          ),
          const SizedBox(height: 20),
          const Text('موقع المكتب ودايرة الحضور', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          GlassCard(
            padding: const EdgeInsets.all(8),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(height: 260, child: _map(active)),
            ),
          ),
          const SizedBox(height: 12),
          if (_offices.isEmpty)
            GlassCard(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Text('لسه محددتش مكان المكتب. الموظفين مش هيتتبعوا لحد ما تضيف مكتب.',
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.onSurfaceVariantLight)),
              ),
            ),
          ..._offices.map((o) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: GlassCard(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.apartment_rounded, color: o['active'] == false ? Colors.grey : AppColors.secondary),
                      const SizedBox(width: 10),
                      Expanded(child: Text('${o['name']}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                      if (o['active'] == false) const Text('متوقف', style: TextStyle(color: Colors.grey)),
                      if (_canEdit) IconButton(icon: const Icon(Icons.edit_location_alt_outlined), onPressed: () => _editOffice(o)),
                    ]),
                    _row('الإحداثيات', '${(o['lat'] as num).toStringAsFixed(6)}, ${(o['lng'] as num).toStringAsFixed(6)}'),
                    _row('نصف قطر الدايرة', '${o['radius_m']} متر'),
                  ]),
                ),
              )),
        ],
      ),
    );
  }

  String _date(Object? iso) {
    final d = DateTime.tryParse('$iso')?.toLocal();
    if (d == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }

  Widget _map(List<Map<String, dynamic>> offices, {LatLng? pick, double? radius, void Function(LatLng)? onTap}) {
    final points = offices.map((o) => LatLng((o['lat'] as num).toDouble(), (o['lng'] as num).toDouble())).toList();
    final center = pick ?? (points.isNotEmpty ? points.first : const LatLng(30.0444, 31.2357)); // Cairo by default
    return FlutterMap(
      options: MapOptions(
        initialCenter: center,
        initialZoom: points.isEmpty && pick == null ? 11 : 16,
        onTap: onTap == null ? null : (_, p) => onTap(p),
      ),
      children: [
        TileLayer(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          userAgentPackageName: 'com.jph.valueattendance',
        ),
        CircleLayer(circles: [
          for (final o in offices)
            CircleMarker(
              point: LatLng((o['lat'] as num).toDouble(), (o['lng'] as num).toDouble()),
              radius: (o['radius_m'] as num).toDouble(),
              useRadiusInMeter: true,
              color: AppColors.primary.withOpacity(0.18),
              borderColor: AppColors.primary,
              borderStrokeWidth: 2,
            ),
          if (pick != null && radius != null)
            CircleMarker(point: pick, radius: radius, useRadiusInMeter: true,
                color: AppColors.secondary.withOpacity(0.2), borderColor: AppColors.secondary, borderStrokeWidth: 2),
        ]),
        MarkerLayer(markers: [
          for (final p in points) Marker(point: p, width: 36, height: 36, child: const Icon(Icons.location_on, color: AppColors.primary, size: 36)),
          if (pick != null) Marker(point: pick, width: 36, height: 36, child: const Icon(Icons.location_on, color: AppColors.secondary, size: 36)),
        ]),
        const SimpleAttributionWidget(source: Text('OpenStreetMap')),
      ],
    );
  }

  InputDecoration _input(String label) => InputDecoration(
        labelText: label,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
      );

  Future<void> _editCompany() async {
    final name = TextEditingController(text: '${_company['name'] ?? ''}');
    final desc = TextEditingController(text: '${_company['description'] ?? ''}');
    final addr = TextEditingController(text: '${_company['address'] ?? ''}');
    final phone = TextEditingController(text: '${_company['phone'] ?? ''}');
    final email = TextEditingController(text: '${_company['email'] ?? ''}');
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _sheet(ctx, 'تعديل بيانات الشركة', [
        TextField(controller: name, decoration: _input('اسم الشركة')),
        const SizedBox(height: 10),
        TextField(controller: desc, maxLines: 3, decoration: _input('نبذة عن الشركة')),
        const SizedBox(height: 10),
        TextField(controller: addr, decoration: _input('العنوان')),
        const SizedBox(height: 10),
        TextField(controller: phone, keyboardType: TextInputType.phone, decoration: _input('تليفون التواصل الرسمي')),
        const SizedBox(height: 10),
        TextField(controller: email, keyboardType: TextInputType.emailAddress, decoration: _input('البريد الرسمي')),
        const SizedBox(height: 16),
        _saveButton(ctx, () async {
          final r = await ApiService.post({'action': 'update_company', 'nameAr': name.text.trim(), 'description': desc.text.trim(),
            'address': addr.text.trim(), 'phone': phone.text.trim(), 'email': email.text.trim()});
          _snack(r);
          if (r['success'] == true && ctx.mounted) Navigator.pop(ctx);
        }),
      ]),
    );
    _loadData();
  }

  Future<void> _editOffice(Map<String, dynamic>? o) async {
    final name = TextEditingController(text: '${o?['name'] ?? 'المكتب الرئيسي'}');
    final radius = TextEditingController(text: '${o?['radius_m'] ?? 100}');
    LatLng? pick = o == null ? null : LatLng((o['lat'] as num).toDouble(), (o['lng'] as num).toDouble());
    bool active = o?['active'] != false;
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        final r = double.tryParse(radius.text) ?? 100;
        return _sheet(ctx, o == null ? 'إضافة مكتب' : 'تعديل المكتب', [
          TextField(controller: name, decoration: _input('اسم المكتب')),
          const SizedBox(height: 10),
          Text('دوس على الخريطة لتحديد مكان المكتب', style: TextStyle(color: AppColors.onSurfaceVariantLight)),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(height: 240, child: _map(const [], pick: pick, radius: r, onTap: (p) => set(() => pick = p))),
          ),
          TextButton.icon(
            icon: const Icon(Icons.my_location_rounded),
            label: const Text('استخدم موقعي الحالي'),
            onPressed: () async {
              try {
                var perm = await Geolocator.checkPermission();
                if (perm == LocationPermission.denied) perm = await Geolocator.requestPermission();
                final pos = await Geolocator.getCurrentPosition(
                    locationSettings: const LocationSettings(accuracy: LocationAccuracy.high, timeLimit: Duration(seconds: 25)));
                set(() => pick = LatLng(pos.latitude, pos.longitude));
              } catch (_) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('شغّل الـ GPS واسمح للتطبيق بالموقع'), backgroundColor: Colors.red));
                }
              }
            },
          ),
          if (pick != null) Text('${pick!.latitude.toStringAsFixed(6)}, ${pick!.longitude.toStringAsFixed(6)}', textAlign: TextAlign.center),
          const SizedBox(height: 10),
          TextField(
            controller: radius,
            keyboardType: TextInputType.number,
            decoration: _input('نصف قطر الدايرة (متر) — من 5 لـ 5000'),
            onChanged: (_) => set(() {}),
          ),
          if (o != null) SwitchListTile(contentPadding: EdgeInsets.zero, value: active, title: const Text('المكتب شغال'), onChanged: (v) => set(() => active = v)),
          const SizedBox(height: 12),
          _saveButton(ctx, () async {
            final rm = int.tryParse(radius.text.trim());
            if (pick == null || rm == null || rm < 5 || rm > 5000 || name.text.trim().length < 2) {
              ScaffoldMessenger.of(ctx).showSnackBar(const SnackBar(content: Text('حدد المكان على الخريطة واكتب الاسم ونصف القطر (من 5 لـ 5000 متر)'), backgroundColor: Colors.red));
              return;
            }
            final res = await ApiService.post({'action': 'save_office', if (o != null) 'id': o['id'], 'name': name.text.trim(),
              'lat': pick!.latitude, 'lng': pick!.longitude, 'radiusM': rm, if (o != null) 'active': active});
            _snack(res);
            if (res['success'] == true && ctx.mounted) Navigator.pop(ctx);
          }),
        ]);
      }),
    );
    _loadData();
  }

  Widget _sheet(BuildContext ctx, String title, List<Widget> children) {
    final isDark = Provider.of<AppController>(ctx, listen: false).isDark;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? Colors.grey.shade900.withOpacity(0.98) : Colors.white.withOpacity(0.98),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: Colors.grey.shade400, borderRadius: BorderRadius.circular(2)))),
            const SizedBox(height: 14),
            Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            ...children,
          ]),
        ),
      ),
    );
  }

  Widget _saveButton(BuildContext ctx, Future<void> Function() onTap) => SizedBox(
        height: 52,
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(backgroundColor: AppColors.primary, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
          onPressed: onTap,
          child: const Text('حفظ', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 16)),
        ),
      );
}
