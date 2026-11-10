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
import '../../widgets/glass_dialog.dart';

/// Branch management screen — list, create, edit branches for the current
/// company context.
///
/// Uses the existing glass UI patterns (GlassCard, InfoTile, PrimaryButton,
/// AppBackground) and AppLocalizations for all visible strings.
/// The backend enforces `company.manage` permission; the client hides the
/// create/edit UI from users who don't have it, but the backend is
/// authoritative.
class BranchesPage extends StatefulWidget {
  const BranchesPage({super.key});

  @override
  State<BranchesPage> createState() => _BranchesPageState();
}

class _BranchesPageState extends State<BranchesPage> {
  List<Map<String, dynamic>> _branches = [];
  bool _loading = true;
  bool _error = false;
  String _errorMessage = '';
  bool _canManage = false;

  @override
  void initState() {
    super.initState();
    _loadBranches();
  }

  Future<void> _loadBranches() async {
    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final res = await ApiService.post({'action': 'get_branches'});
      if (mounted) {
        setState(() {
          _loading = false;
          if (res['success'] == true) {
            _branches = (res['branches'] as List?)
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
            AppLocalizations.of(context, 'branches'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          actions: [
            // Company selector button
            if (context.select<AppController, bool>(
                (c) => c.hasMultipleCompanies))
              IconButton(
                icon: const Icon(Icons.business_outlined),
                tooltip: AppLocalizations.of(context, 'switch_company'),
                onPressed: () => CompanySelectorSheet.show(context),
              ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: _loadBranches,
            ),
          ],
        ),
        body: _buildBody(),
        floatingActionButton: _canManage
            ? FloatingActionButton(
                onPressed: () => _showAddBranchDialog(),
                backgroundColor: AppColors.primary,
                child: const Icon(Icons.add, color: Colors.white),
              )
            : null,
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
            Text(
              AppLocalizations.of(context, 'loading_branches'),
              style: TextStyle(
                color: AppColors.onSurfaceVariantLight,
              ),
            ),
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
              onTap: _loadBranches,
            ),
          ],
        ),
      );
    }

    if (_branches.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.business_outlined,
                size: 48,
                color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context, 'no_branches'),
              style: TextStyle(color: AppColors.onSurfaceVariantLight),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadBranches,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _branches.length,
        itemBuilder: (context, index) => _BranchCard(
          branch: _branches[index],
          canManage: _canManage,
          onEdit: () => _showEditBranchDialog(_branches[index]),
        ),
      ),
    );
  }

  void _showAddBranchDialog() {
    _showBranchFormDialog(branch: null);
  }

  void _showEditBranchDialog(Map<String, dynamic> branch) {
    _showBranchFormDialog(branch: branch);
  }

  void _showBranchFormDialog({Map<String, dynamic>? branch}) {
    final isEdit = branch != null;
    final codeController =
        TextEditingController(text: branch?['code']?.toString() ?? '');
    final nameController =
        TextEditingController(text: branch?['name']?.toString() ?? '');
    final addressController =
        TextEditingController(text: branch?['address']?.toString() ?? '');
    final phoneController =
        TextEditingController(text: branch?['phone']?.toString() ?? '');
    final timezoneController =
        TextEditingController(text: branch?['timezone']?.toString() ?? '');

    showDialog(
      context: context,
      builder: (dialogContext) => GlassAlertDialog(
        title: Text(
          isEdit
              ? AppLocalizations.of(dialogContext, 'edit_branch')
              : AppLocalizations.of(dialogContext, 'add_branch'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: codeController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'branch_code'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'branch_name'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: addressController,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizations.of(dialogContext, 'branch_address'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: phoneController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'branch_phone'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: timezoneController,
                decoration: InputDecoration(
                  labelText:
                      AppLocalizations.of(dialogContext, 'branch_timezone'),
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
                'action': isEdit ? 'update_branch' : 'add_branch',
                'code': codeController.text.trim(),
                'name': nameController.text.trim(),
                if (addressController.text.isNotEmpty)
                  'address': addressController.text.trim(),
                if (phoneController.text.isNotEmpty)
                  'phone': phoneController.text.trim(),
                if (timezoneController.text.isNotEmpty)
                  'timezone': timezoneController.text.trim(),
              };
              if (isEdit) {
                payload['id'] = branch!['id']?.toString() ?? '';
              }

              final res = await ApiService.post(payload);
              if (dialogContext.mounted) {
                if (res['success'] == true) {
                  Navigator.of(dialogContext).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                        AppLocalizations.of(
                            context,
                            isEdit
                                ? 'branch_updated_success'
                                : 'branch_added_success'),
                      ),
                    ),
                  );
                  _loadBranches();
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(res['message']?.toString() ??
                          AppLocalizations.of(context, 'operation_failed')),
                    ),
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

class _BranchCard extends StatelessWidget {
  final Map<String, dynamic> branch;
  final bool canManage;
  final VoidCallback onEdit;

  const _BranchCard({
    required this.branch,
    required this.canManage,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final name = branch['name']?.toString() ?? '';
    final code = branch['code']?.toString() ?? '';
    final address = branch['address']?.toString() ?? '';
    final phone = branch['phone']?.toString() ?? '';
    final status = branch['status']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.store_outlined,
                    color: AppColors.primary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                      Text(
                        code,
                        style: TextStyle(
                          fontSize: 13,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                // Status badge
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: status == 'active'
                        ? AppColors.secondary.withOpacity(0.15)
                        : AppColors.error.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: status == 'active'
                          ? AppColors.secondary
                          : AppColors.error,
                    ),
                  ),
                ),
              ],
            ),
            if (address.isNotEmpty || phone.isNotEmpty) ...[
              const SizedBox(height: 12),
              if (address.isNotEmpty)
                InfoTile(
                  title: AppLocalizations.of(context, 'branch_address'),
                  value: address,
                ),
              if (phone.isNotEmpty)
                InfoTile(
                  title: AppLocalizations.of(context, 'branch_phone'),
                  value: phone,
                ),
            ],
            if (canManage) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit, size: 18),
                  label: Text(AppLocalizations.of(context, 'edit')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
