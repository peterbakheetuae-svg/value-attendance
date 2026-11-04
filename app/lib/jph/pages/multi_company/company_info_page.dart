import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/company_selector_sheet.dart';
import '../../services/api_service.dart';

/// Company info screen — shows the current company's details and its
/// subsidiaries. Uses the existing glass UI patterns.
class CompanyInfoPage extends StatefulWidget {
  const CompanyInfoPage({super.key});

  @override
  State<CompanyInfoPage> createState() => _CompanyInfoPageState();
}

class _CompanyInfoPageState extends State<CompanyInfoPage> {
  Map<String, dynamic> _companyInfo = {};
  List<Map<String, dynamic>> _subsidiaries = [];
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

    try {
      final infoRes = await ApiService.post({'action': 'get_company_info'});
      final treeRes = await ApiService.post({'action': 'get_company_tree'});

      if (mounted) {
        setState(() {
          _loading = false;
          if (infoRes['success'] == true) {
            _companyInfo = infoRes;
          } else {
            _error = true;
            _errorMessage = infoRes['message']?.toString() ?? '';
          }
          if (treeRes['success'] == true) {
            final subs = treeRes['subsidiaries'];
            if (subs is List) {
              _subsidiaries = subs
                  .whereType<Map>()
                  .map((m) => m.cast<String, dynamic>())
                  .toList();
            }
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
            AppLocalizations.of(context, 'company_info'),
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
              onPressed: _loadData,
            ),
          ],
        ),
        body: _buildBody(),
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
              AppLocalizations.of(context, 'loading_data'),
              style: TextStyle(color: AppColors.onSurfaceVariantLight),
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
          ],
        ),
      );
    }

    final companyData = (_companyInfo['data'] as Map?)?.cast<String, dynamic>() ??
        _companyInfo;

    return RefreshIndicator(
      onRefresh: _loadData,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // Company info card
          GlassCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Icon(
                        Icons.business,
                        color: AppColors.primary,
                        size: 26,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        companyData['name']?.toString() ??
                            AppLocalizations.of(context, 'company'),
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                InfoTile(
                  title: AppLocalizations.of(context, 'company_code'),
                  value: companyData['code']?.toString() ?? '-',
                ),
                InfoTile(
                  title: AppLocalizations.of(context, 'company_currency'),
                  value: companyData['currency']?.toString() ?? '-',
                ),
                InfoTile(
                  title: AppLocalizations.of(context, 'company_status'),
                  value: companyData['status']?.toString() ?? '-',
                ),
                if (companyData['timezone'] != null)
                  InfoTile(
                    title: AppLocalizations.of(context, 'branch_timezone'),
                    value: companyData['timezone'].toString(),
                  ),
                if (companyData['address'] != null)
                  InfoTile(
                    title: AppLocalizations.of(context, 'branch_address'),
                    value: companyData['address'].toString(),
                  ),
                if (companyData['phone'] != null)
                  InfoTile(
                    title: AppLocalizations.of(context, 'branch_phone'),
                    value: companyData['phone'].toString(),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          // Subsidiaries section
          Text(
            AppLocalizations.of(context, 'subsidiaries'),
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          if (_subsidiaries.isEmpty)
            GlassCard(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    AppLocalizations.of(context, 'no_data'),
                    style: TextStyle(
                      color: AppColors.onSurfaceVariantLight,
                    ),
                  ),
                ),
              ),
            )
          else
            ..._subsidiaries.map((sub) => _SubsidiaryTile(subsidiary: sub)),
        ],
      ),
    );
  }
}

class _SubsidiaryTile extends StatelessWidget {
  final Map<String, dynamic> subsidiary;

  const _SubsidiaryTile({required this.subsidiary});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final name = subsidiary['name']?.toString() ?? '';
    final code = subsidiary['code']?.toString() ?? '';
    final currency = subsidiary['currency']?.toString() ?? '';

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        showShadow: false,
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppColors.secondary.withOpacity(0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.business_outlined,
                color: AppColors.secondary,
                size: 18,
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
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                  Text(
                    code.isNotEmpty ? '$code · $currency' : currency,
                    style: TextStyle(fontSize: 12, color: subtitleColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
