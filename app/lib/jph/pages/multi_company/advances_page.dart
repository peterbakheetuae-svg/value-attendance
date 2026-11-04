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

/// Advances management screen — list, submit, approve/reject advance requests.
///
/// Uses the single `/advances/:id/decision` endpoint with
/// `decision: 'approved' | 'rejected'`. The two-stage CEO/accountant flow
/// is governed by backend role permissions, not separate routes.
class AdvancesPage extends StatefulWidget {
  const AdvancesPage({super.key});

  @override
  State<AdvancesPage> createState() => _AdvancesPageState();
}

class _AdvancesPageState extends State<AdvancesPage> {
  List<Map<String, dynamic>> _advances = [];
  bool _loading = true;
  bool _error = false;
  String _errorMessage = '';
  String? _statusFilter;

  @override
  void initState() {
    super.initState();
    _loadAdvances();
  }

  Future<void> _loadAdvances() async {
    setState(() {
      _loading = true;
      _error = false;
    });

    try {
      final res = await ApiService.post({
        'action': 'get_advances',
        if (_statusFilter != null) 'status': _statusFilter,
      });
      if (mounted) {
        setState(() {
          _loading = false;
          if (res['success'] == true) {
            _advances = (res['advances'] as List?)
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
            AppLocalizations.of(context, 'advance_requests'),
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
              onPressed: _loadAdvances,
            ),
          ],
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(48),
            child: _buildStatusFilter(),
          ),
        ),
        body: _buildBody(),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showSubmitAdvanceDialog(),
          backgroundColor: AppColors.primary,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildStatusFilter() {
    final statuses = ['all', 'pending', 'approved', 'rejected', 'cancelled'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: statuses.map((status) {
            final isSelected = (_statusFilter == status) ||
                (_statusFilter == null && status == 'all');
            final label = status == 'all'
                ? AppLocalizations.of(context, 'all')
                : AppLocalizations.of(context, status);

            return Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(label),
                selected: isSelected,
                onSelected: (_) {
                  setState(() {
                    _statusFilter = status == 'all' ? null : status;
                  });
                  _loadAdvances();
                },
                selectedColor: AppColors.primary.withOpacity(0.15),
                checkmarkColor: AppColors.primary,
              ),
            );
          }).toList(),
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
            Text(AppLocalizations.of(context, 'loading_advances'),
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
              onTap: _loadAdvances,
            ),
          ],
        ),
      );
    }

    if (_advances.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.payments_outlined,
                size: 48,
                color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context, 'no_advances'),
              style: TextStyle(color: AppColors.onSurfaceVariantLight),
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadAdvances,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _advances.length,
        itemBuilder: (context, index) => _AdvanceCard(
          advance: _advances[index],
          onApprove: () => _decideAdvance(_advances[index], 'approved'),
          onReject: () => _decideAdvance(_advances[index], 'rejected'),
        ),
      ),
    );
  }

  void _showSubmitAdvanceDialog() {
    final amountController = TextEditingController();
    final noteController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(AppLocalizations.of(dialogContext, 'advance_requests')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: AppLocalizations.of(dialogContext, 'advance_amount'),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: noteController,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: AppLocalizations.of(dialogContext, 'reason'),
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(AppLocalizations.of(dialogContext, 'cancel')),
          ),
          ElevatedButton(
            onPressed: () async {
              final res = await ApiService.post({
                'action': 'submit_advance',
                'amount': double.tryParse(amountController.text) ?? 0,
                if (noteController.text.isNotEmpty)
                  'note': noteController.text.trim(),
              });
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
                if (res['success'] == true) {
                  _loadAdvances();
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

  void _decideAdvance(Map<String, dynamic> advance, String decision) async {
    final id = advance['id']?.toString() ?? '';

    String? reason;
    if (decision == 'rejected') {
      reason = await _showReasonDialog();
      if (reason == null) return; // cancelled
    }

    final res = await ApiService.post({
      'action': decision == 'approved' ? 'approve_advance_ceo' : 'reject_advance',
      'id': id,
      if (reason != null) 'reason': reason,
    });

    if (mounted) {
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppLocalizations.of(
                context,
                decision == 'approved'
                    ? 'advance_approved'
                    : 'advance_rejected',
              ),
            ),
          ),
        );
        _loadAdvances();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message']?.toString() ?? '')),
        );
      }
    }
  }

  Future<String?> _showReasonDialog() async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(AppLocalizations.of(ctx, 'rejection_reason')),
        content: TextField(
          controller: controller,
          maxLines: 3,
          decoration: InputDecoration(
            border: const OutlineInputBorder(),
            hintText: AppLocalizations.of(ctx, 'please_enter_reason'),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(null),
            child: Text(AppLocalizations.of(ctx, 'cancel')),
          ),
          ElevatedButton(
            onPressed: () =>
                Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(AppLocalizations.of(ctx, 'confirm')),
          ),
        ],
      ),
    );
  }
}

class _AdvanceCard extends StatelessWidget {
  final Map<String, dynamic> advance;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const _AdvanceCard({
    required this.advance,
    required this.onApprove,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final amount = advance['amount']?.toString() ?? '0';
    final currency = advance['currency']?.toString() ?? '';
    final status = advance['status']?.toString() ?? 'pending';
    final note = advance['note']?.toString() ?? '';
    final createdAt = advance['createdAt']?.toString() ?? '';
    final userName = advance['userName']?.toString() ??
        advance['user']?['fullName']?.toString() ??
        '';

    final statusColor = status == 'approved'
        ? AppColors.secondary
        : status == 'rejected'
            ? AppColors.error
            : AppColors.accent;

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
                    color: AppColors.accent.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.payments,
                      color: AppColors.accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (userName.isNotEmpty)
                        Text(
                          userName,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: textColor,
                          ),
                        ),
                      Text(
                        '$amount $currency',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    AppLocalizations.of(context, status),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            if (note.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                note,
                style: TextStyle(fontSize: 13, color: subtitleColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (createdAt.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                createdAt,
                style: TextStyle(fontSize: 11, color: subtitleColor),
              ),
            ],
            if (status == 'pending') ...[
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: onReject,
                    icon: Icon(Icons.close, size: 18, color: AppColors.error),
                    label: Text(
                      AppLocalizations.of(context, 'reject'),
                      style: TextStyle(color: AppColors.error),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: onApprove,
                    icon: const Icon(Icons.check, size: 18),
                    label: Text(AppLocalizations.of(context, 'approve')),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.secondary,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
