import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/company_selector_sheet.dart';
import '../../services/api_service.dart';

/// Work locations (geofence) management screen — list, create, edit
/// geofence locations for the current company context.
class WorkLocationsPage extends StatefulWidget {
  const WorkLocationsPage({super.key});

  @override
  State<WorkLocationsPage> createState() => _WorkLocationsPageState();
}

class _WorkLocationsPageState extends State<WorkLocationsPage> {
  List<Map<String, dynamic>> _locations = [];
  bool _loading = true;
  bool _error = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _loadLocations();
  }

  Future<void> _loadLocations() async {
    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final res = await ApiService.post({'action': 'get_work_locations'});
      if (mounted) {
        setState(() {
          _loading = false;
          if (res['success'] == true) {
            _locations = (res['workLocations'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
          } else {
            _error = true;
            _errorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = true;
          _errorMessage = e.toString();
        });
      }
    }
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
            AppLocalizations.of(context, 'work_locations'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            if (context.select<AppController, bool>(
                (c) => c.hasMultipleCompanies))
              IconButton(
                icon: const Icon(Icons.business_outlined),
                tooltip: AppLocalizations.of(context, 'switch_company'),
                onPressed: () => CompanySelectorSheet.show(context),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadLocations,
            ),
          ],
        ),
        body: _buildBody(),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showAddLocationDialog(),
          backgroundColor: AppColors.primary,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(AppLocalizations.of(context, 'loading_data'),
                style: TextStyle(color: AppColors.onSurfaceVariantLight)),
          ],
        ),
      );
    }

    if (_error) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: 12),
            Text(
              _errorMessage.isNotEmpty
                  ? _errorMessage
                  : AppLocalizations.of(context, 'error_occurred'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.onSurfaceVariantLight),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: AppLocalizations.of(context, 'retry'),
              onTap: _loadLocations,
            ),
          ],
        ),
      );
    }

    if (_locations.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.location_off_outlined,
                size: 48,
                color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context, 'no_data'),
              style: TextStyle(color: AppColors.onSurfaceVariantLight),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadLocations,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _locations.length,
        itemBuilder: (context, index) => _LocationCard(
          location: _locations[index],
          onEdit: () => _showEditLocationDialog(_locations[index]),
        ),
      ),
    );
  }

  void _showAddLocationDialog() {
    _showLocationFormDialog(location: null);
  }

  void _showEditLocationDialog(Map<String, dynamic> location) {
    _showLocationFormDialog(location: location);
  }

  void _showLocationFormDialog({Map<String, dynamic>? location}) {
    final isEdit = location != null;
    final nameController =
        TextEditingController(text: location?['name']?.toString() ?? '');
    final latController = TextEditingController(
        text: location?['latitude']?.toString() ?? '');
    final lngController = TextEditingController(
        text: location?['longitude']?.toString() ?? '');
    final radiusController = TextEditingController(
        text: location?['radiusM']?.toString() ?? '100');

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          isEdit
              ? AppLocalizations.of(dialogContext, 'edit_work_location')
              : AppLocalizations.of(dialogContext, 'add_work_location'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'work_location_name'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: latController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(dialogContext, 'latitude'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: lngController,
                      keyboardType:
                          const TextInputType.numberWithOptions(decimal: true),
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(dialogContext, 'longitude'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: radiusController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'radius_meters'),
                  border: const OutlineInputBorder(),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(dialogContext, 'cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              final payload = <String, dynamic>{
                'action':
                    isEdit ? 'update_work_location' : 'add_work_location',
                'name': nameController.text.trim(),
                'latitude': double.tryParse(latController.text) ?? 0,
                'longitude': double.tryParse(lngController.text) ?? 0,
                'radiusM': int.tryParse(radiusController.text) ?? 100,
              };
              if (isEdit) {
                payload['id'] = location!['id']?.toString() ?? '';
              }

              final res = await ApiService.post(payload);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
                if (res['success'] == true) {
                  _loadLocations();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(res['message']?.toString() ?? '')),
                  );
                }
              }
            },
            child: Text(AppLocalizations.of(dialogContext, 'save')),
          ),
        ],
      ),
    );
  }
}

class _LocationCard extends StatelessWidget {
  final Map<String, dynamic> location;
  final VoidCallback onEdit;

  const _LocationCard({required this.location, required this.onEdit});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;

    final name = location['name']?.toString() ?? '';
    final lat = location['latitude']?.toString() ?? '';
    final lng = location['longitude']?.toString() ?? '';
    final radius = location['radiusM']?.toString() ?? '';
    final isActive = location['isActive'] == true;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.location_on,
                      color: AppColors.secondary, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.secondary.withOpacity(0.15)
                        : AppColors.error.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isActive
                        ? AppLocalizations.of(context, 'kpi_active')
                        : AppLocalizations.of(context, 'kpi_inactive'),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: isActive ? AppColors.secondary : AppColors.error,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InfoTile(title: AppLocalizations.of(context, 'latitude'), value: lat),
            InfoTile(title: AppLocalizations.of(context, 'longitude'), value: lng),
            InfoTile(title: AppLocalizations.of(context, 'radius_meters'), value: '${radius}m'),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: onEdit,
                icon: const Icon(Icons.edit, size: 18),
                label: Text(AppLocalizations.of(context, 'edit')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
