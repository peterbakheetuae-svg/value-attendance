import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_colors.dart';

/// A bottom-sheet / dialog widget that shows the list of companies the user
/// is authorised on, and lets them switch the active company context.
///
/// The list comes from [AppController.availableCompanies], which is populated
/// from the `/me` response at login. Only companies the backend has authorised
/// appear here — the client never invents entries.
///
/// The selected company UUID is stored via [AppController.switchCompany], and
/// all subsequent API calls include it as the `companyId` query parameter.
/// The backend re-checks authorisation on every request, so a revoked
/// membership will produce a 403, not a data leak.
class CompanySelectorSheet extends StatelessWidget {
  const CompanySelectorSheet({super.key});

  /// Shows the sheet as a modal bottom sheet.
  static Future<void> show(BuildContext context) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const CompanySelectorSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final appController = Provider.of<AppController>(context);
    final isDark = appController.isDark;
    final companies = appController.availableCompanies;
    final currentId = appController.currentCompanyId;

    final bgColor = isDark
        ? AppColors.surfaceDark.withOpacity(0.95)
        : AppColors.surfaceLight.withOpacity(0.95);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;
    final borderColor = isDark
        ? AppColors.outlineDark.withOpacity(0.3)
        : AppColors.outlineLight.withOpacity(0.2);

    return Container(
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
        border: Border(top: BorderSide(color: borderColor, width: 1)),
      ),
      child: SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Padding(
                padding: const EdgeInsets.only(top: 12, bottom: 4),
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: subtitleColor.withOpacity(0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.business_outlined,
                      color: isDark ? AppColors.primaryLight : AppColors.primary,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      AppLocalizations.of(context, 'select_company'),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: textColor,
                      ),
                    ),
                  ],
                ),
              ),
              // Companies list
              if (companies.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    children: [
                      Icon(
                        Icons.business,
                        size: 48,
                        color: subtitleColor.withOpacity(0.5),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        AppLocalizations.of(context, 'no_companies_available'),
                        style: TextStyle(
                          fontSize: 14,
                          color: subtitleColor,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                )
              else
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                    itemCount: companies.length,
                    itemBuilder: (context, index) {
                      final company = companies[index];
                      final companyId = company['id']?.toString() ?? '';
                      final name = company['name']?.toString() ?? '';
                      final code = company['code']?.toString() ?? '';
                      final currency = company['currency']?.toString() ?? '';
                      final status = company['status']?.toString() ?? '';
                      final roleKey = company['roleKey']?.toString();

                      final isSelected = companyId == currentId;
                      final isHome = companyId == appController.homeCompanyId;

                      return _CompanyTile(
                        name: name,
                        code: code,
                        currency: currency,
                        status: status,
                        roleKey: roleKey,
                        isSelected: isSelected,
                        isHome: isHome,
                        isDark: isDark,
                        onTap: () {
                          appController.switchCompany(companyId);
                          Navigator.of(context).pop();
                        },
                      );
                    },
                  ),
                ),
              // Reset to home company button
              if (companies.isNotEmpty &&
                  appController.currentCompanyId != appController.homeCompanyId)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
                  child: TextButton.icon(
                    onPressed: () {
                      appController.switchCompany(null);
                      Navigator.of(context).pop();
                    },
                    icon: Icon(
                      Icons.restore,
                      size: 18,
                      color: isDark
                          ? AppColors.primaryLight
                          : AppColors.primary,
                    ),
                    label: Text(
                      AppLocalizations.of(context, 'reset_to_home_company'),
                      style: TextStyle(
                        color: isDark
                            ? AppColors.primaryLight
                            : AppColors.primary,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

class _CompanyTile extends StatelessWidget {
  final String name;
  final String code;
  final String currency;
  final String status;
  final String? roleKey;
  final bool isSelected;
  final bool isHome;
  final bool isDark;
  final VoidCallback onTap;

  const _CompanyTile({
    required this.name,
    required this.code,
    required this.currency,
    required this.status,
    required this.roleKey,
    required this.isSelected,
    required this.isHome,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;
    final selectedBg = (isDark ? AppColors.primaryLight : AppColors.primary)
        .withOpacity(0.12);
    final borderColor = isSelected
        ? (isDark ? AppColors.primaryLight : AppColors.primary)
        : (isDark
            ? AppColors.outlineDark.withOpacity(0.15)
            : AppColors.outlineLight.withOpacity(0.1));

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: isSelected ? selectedBg : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: borderColor, width: isSelected ? 1.5 : 1),
            ),
            child: Row(
              children: [
                // Company icon
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: (isDark ? AppColors.primaryLight : AppColors.primary)
                        .withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.business_outlined,
                    size: 20,
                    color: isDark ? AppColors.primaryLight : AppColors.primary,
                  ),
                ),
                const SizedBox(width: 12),
                // Company info
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              name,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: textColor,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isHome) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.secondary.withOpacity(0.15),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                AppLocalizations.of(context, 'home'),
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.secondary,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        code.isNotEmpty
                            ? '$code · $currency'
                            : currency,
                        style: TextStyle(
                          fontSize: 12,
                          color: subtitleColor,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Selected check or chevron
                if (isSelected)
                  Icon(
                    Icons.check_circle,
                    size: 22,
                    color: isDark ? AppColors.primaryLight : AppColors.primary,
                  )
                else
                  Icon(
                    Icons.chevron_right,
                    size: 22,
                    color: subtitleColor.withOpacity(0.5),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
