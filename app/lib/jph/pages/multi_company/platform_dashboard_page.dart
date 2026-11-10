import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/primary_button.dart';
import '../../services/api_service.dart';
import '../../widgets/glass_dialog.dart';

/// Platform Owner dashboard — plans, subscriptions, and billing events.
///
/// Only visible when `isPlatformOwner` is true. The backend enforces
/// `requirePlatformOwner()` on every `/platform/*` route, so even if the
/// flag is wrong, the API rejects the call.
///
/// **Billing events are synthetic** — `payment_source` has a CHECK constraint
/// forcing it to `'synthetic'`. The UI displays a prominent label stating
/// this is not real financial data.
class PlatformDashboardPage extends StatefulWidget {
  const PlatformDashboardPage({super.key});

  @override
  State<PlatformDashboardPage> createState() => _PlatformDashboardPageState();
}

class _PlatformDashboardPageState extends State<PlatformDashboardPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // ── Plans ──
  List<Map<String, dynamic>> _plans = [];
  bool _loadingPlans = true;
  bool _plansError = false;
  String _plansErrorMessage = '';

  // ── Subscriptions ──
  List<Map<String, dynamic>> _subscriptions = [];
  bool _loadingSubscriptions = true;
  bool _subscriptionsError = false;
  String _subscriptionsErrorMessage = '';

  // ── Billing ──
  List<Map<String, dynamic>> _billingEvents = [];
  bool _loadingBilling = false;
  bool _billingError = false;
  String _billingErrorMessage = '';
  bool _billingSynthetic = true;

  // ── Company subscription ──
  Map<String, dynamic>? _companySubscription;
  bool _loadingCompanySub = false;
  bool _companySubError = false;
  String _companySubErrorMessage = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _onTabChanged(_tabController.index);
      }
    });
    _loadPlans();
    _loadSubscriptions();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged(int index) {
    if (index == 2 && _billingEvents.isEmpty && !_loadingBilling) {
      _loadBilling();
    } else if (index == 3 && _companySubscription == null && !_loadingCompanySub) {
      _loadCompanySubscription();
    }
  }

  // ===========================================================================
  // API calls
  // ===========================================================================

  Future<void> _loadPlans() async {
    setState(() {
      _loadingPlans = true;
      _plansError = false;
    });

    try {
      final res = await ApiService.post({'action': 'get_platform_plans'});
      if (mounted) {
        setState(() {
          _loadingPlans = false;
          if (res['success'] == true) {
            _plans = (res['plans'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
          } else {
            _plansError = true;
            _plansErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingPlans = false;
          _plansError = true;
          _plansErrorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadSubscriptions() async {
    setState(() {
      _loadingSubscriptions = true;
      _subscriptionsError = false;
    });

    try {
      final res = await ApiService.post({'action': 'get_platform_subscriptions'});
      if (mounted) {
        setState(() {
          _loadingSubscriptions = false;
          if (res['success'] == true) {
            _subscriptions = (res['subscriptions'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
          } else {
            _subscriptionsError = true;
            _subscriptionsErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingSubscriptions = false;
          _subscriptionsError = true;
          _subscriptionsErrorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadBilling() async {
    setState(() {
      _loadingBilling = true;
      _billingError = false;
    });

    try {
      final res = await ApiService.post({'action': 'get_platform_billing'});
      if (mounted) {
        setState(() {
          _loadingBilling = false;
          if (res['success'] == true) {
            _billingEvents = (res['events'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
            _billingSynthetic = res['synthetic'] == true;
          } else {
            _billingError = true;
            _billingErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingBilling = false;
          _billingError = true;
          _billingErrorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadCompanySubscription() async {
    setState(() {
      _loadingCompanySub = true;
      _companySubError = false;
    });

    try {
      final res = await ApiService.post({'action': 'get_company_subscription'});
      if (mounted) {
        setState(() {
          _loadingCompanySub = false;
          if (res['success'] == true) {
            _companySubscription = res;
          } else {
            _companySubError = true;
            _companySubErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingCompanySub = false;
          _companySubError = true;
          _companySubErrorMessage = e.toString();
        });
      }
    }
  }

  // ===========================================================================
  // Actions
  // ===========================================================================

  void _suspendSubscription(Map<String, dynamic> subscription) async {
    final id = subscription['id']?.toString() ?? '';
    final reason = await _showReasonDialog();

    if (reason == null) return;

    final res = await ApiService.post({
      'action': 'suspend_subscription',
      'id': id,
      'reason': reason,
    });

    if (mounted) {
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                AppLocalizations.of(context, 'subscription_suspended')),
          ),
        );
        _loadSubscriptions();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(res['message']?.toString() ?? '')),
        );
      }
    }
  }

  void _reactivateSubscription(Map<String, dynamic> subscription) async {
    final id = subscription['id']?.toString() ?? '';

    final res = await ApiService.post({
      'action': 'reactivate_subscription',
      'id': id,
    });

    if (mounted) {
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                AppLocalizations.of(context, 'subscription_reactivated')),
          ),
        );
        _loadSubscriptions();
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
      builder: (ctx) => GlassAlertDialog(
        title: Text(AppLocalizations.of(ctx, 'suspend_reason')),
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
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(AppLocalizations.of(ctx, 'confirm')),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    final isPlatformOwner =
        context.select<AppController, bool>((c) => c.isPlatformOwner);

    if (!isPlatformOwner) {
      return AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: Text(
              AppLocalizations.of(context, 'platform_dashboard'),
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline,
                      size: 48,
                      color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
                  const SizedBox(height: 12),
                  Text(
                    AppLocalizations.of(context, 'permission_required_action'),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppColors.onSurfaceVariantLight),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            AppLocalizations.of(context, 'platform_dashboard'),
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
          bottom: TabBar(
            controller: _tabController,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.onSurfaceVariantLight,
            indicatorColor: AppColors.primary,
            tabs: [
              Tab(text: AppLocalizations.of(context, 'platform_plans')),
              Tab(
                  text:
                      AppLocalizations.of(context, 'platform_subscriptions')),
              Tab(text: AppLocalizations.of(context, 'platform_billing')),
              Tab(text: AppLocalizations.of(context, 'company_info')),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildPlansTab(),
            _buildSubscriptionsTab(),
            _buildBillingTab(),
            _buildCompanySubscriptionTab(),
          ],
        ),
      ),
    );
  }

  // ── Plans Tab ──

  Widget _buildPlansTab() {
    if (_loadingPlans) {
      return _buildLoading(AppLocalizations.of(context, 'loading_plans'));
    }
    if (_plansError) {
      return _buildError(_plansErrorMessage, _loadPlans);
    }
    if (_plans.isEmpty) {
      return _buildEmpty(
          AppLocalizations.of(context, 'no_plans'), Icons.layers_outlined);
    }

    return RefreshIndicator(
      onRefresh: _loadPlans,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _plans.length,
        itemBuilder: (context, index) =>
            _PlanCard(plan: _plans[index]),
      ),
    );
  }

  // ── Subscriptions Tab ──

  Widget _buildSubscriptionsTab() {
    if (_loadingSubscriptions) {
      return _buildLoading(
          AppLocalizations.of(context, 'loading_subscriptions'));
    }
    if (_subscriptionsError) {
      return _buildError(_subscriptionsErrorMessage, _loadSubscriptions);
    }
    if (_subscriptions.isEmpty) {
      return _buildEmpty(AppLocalizations.of(context, 'no_subscriptions'),
          Icons.card_membership_outlined);
    }

    return RefreshIndicator(
      onRefresh: _loadSubscriptions,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _subscriptions.length,
        itemBuilder: (context, index) => _SubscriptionCard(
          subscription: _subscriptions[index],
          onSuspend: () => _suspendSubscription(_subscriptions[index]),
          onReactivate: () =>
              _reactivateSubscription(_subscriptions[index]),
        ),
      ),
    );
  }

  // ── Billing Tab ──

  Widget _buildBillingTab() {
    if (_loadingBilling) {
      return _buildLoading(AppLocalizations.of(context, 'loading_report'));
    }
    if (_billingError) {
      return _buildError(_billingErrorMessage, _loadBilling);
    }
    if (_billingEvents.isEmpty) {
      return _buildEmpty(AppLocalizations.of(context, 'no_billing_events'),
          Icons.receipt_long_outlined);
    }

    return RefreshIndicator(
      onRefresh: _loadBilling,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _billingEvents.length + 1,
        itemBuilder: (context, index) {
          // First item: synthetic data warning banner
          if (index == 0) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: GlassCard(
                backgroundColor:
                    AppColors.warning.withOpacity(0.1),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded,
                        color: AppColors.warning, size: 24),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            AppLocalizations.of(
                                context, 'billing_synthetic'),
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color: AppColors.warning,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            AppLocalizations.of(context,
                                'billing_synthetic_note'),
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.onSurfaceVariantLight,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }
          return _BillingEventCard(
              event: _billingEvents[index - 1]);
        },
      ),
    );
  }

  // ── Company Subscription Tab ──

  Widget _buildCompanySubscriptionTab() {
    if (_loadingCompanySub) {
      return _buildLoading(
          AppLocalizations.of(context, 'loading_subscriptions'));
    }
    if (_companySubError) {
      return _buildError(_companySubErrorMessage, _loadCompanySubscription);
    }
    if (_companySubscription == null) {
      return _buildEmpty(AppLocalizations.of(context, 'no_subscriptions'),
          Icons.card_membership_outlined);
    }

    final sub = _companySubscription!;
    final data = sub['data'] as Map<String, dynamic>? ?? sub;

    return RefreshIndicator(
      onRefresh: _loadCompanySubscription,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(context, 'platform_subscriptions'),
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              InfoTile(
                title: AppLocalizations.of(context, 'subscription_status'),
                value: data['status']?.toString() ?? '',
              ),
              InfoTile(
                title: AppLocalizations.of(context, 'plan_name'),
                value: data['planName']?.toString() ??
                    data['plan']?['name']?.toString() ??
                    '',
              ),
              InfoTile(
                title: AppLocalizations.of(context, 'plan_max_employees'),
                value:
                    '${data['maxEmployees'] ?? data['plan']?['maxEmployees'] ?? ''}',
              ),
              InfoTile(
                title: AppLocalizations.of(
                    context, 'plan_included_branches'),
                value:
                    '${data['includedBranches'] ?? data['plan']?['includedBranches'] ?? ''}',
              ),
              if (data['currency'] != null)
                InfoTile(
                  title: AppLocalizations.of(context, 'currency'),
                  value: data['currency']?.toString() ?? '',
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Shared widgets ──

  Widget _buildLoading(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(message,
              style: TextStyle(color: AppColors.onSurfaceVariantLight)),
        ],
      ),
    );
  }

  Widget _buildError(String message, VoidCallback onRetry) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 48, color: AppColors.error),
            const SizedBox(height: 12),
            Text(
              message.isNotEmpty
                  ? message
                  : AppLocalizations.of(context, 'error_occurred'),
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.onSurfaceVariantLight),
            ),
            const SizedBox(height: 16),
            PrimaryButton(
              label: AppLocalizations.of(context, 'retry'),
              onTap: onRetry,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(String message, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon,
              size: 48,
              color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text(message,
              style: TextStyle(color: AppColors.onSurfaceVariantLight)),
        ],
      ),
    );
  }
}

// =============================================================================
// Card widgets
// =============================================================================

class _PlanCard extends StatelessWidget {
  final Map<String, dynamic> plan;

  const _PlanCard({required this.plan});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final name = plan['name']?.toString() ?? '';
    final status = plan['status']?.toString() ?? '';
    final includedBranches = plan['includedBranches'] ?? 0;
    final maxEmployees = plan['maxEmployees'] ?? 0;
    final addonPrice = plan['branchAddonPrice'] ?? 0;
    final addonCurrency =
        plan['branchAddonCurrency']?.toString() ?? '';

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
                  child: Icon(Icons.layers_outlined,
                      color: AppColors.primary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
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
            const SizedBox(height: 12),
            InfoTile(
              title: AppLocalizations.of(
                  context, 'plan_included_branches'),
              value: '$includedBranches',
            ),
            InfoTile(
              title:
                  AppLocalizations.of(context, 'plan_max_employees'),
              value: '$maxEmployees',
            ),
            if (addonPrice != null && addonPrice != 0)
              InfoTile(
                title: AppLocalizations.of(
                    context, 'plan_branch_addon_price'),
                value: '$addonPrice $addonCurrency',
              ),
          ],
        ),
      ),
    );
  }
}

class _SubscriptionCard extends StatelessWidget {
  final Map<String, dynamic> subscription;
  final VoidCallback onSuspend;
  final VoidCallback onReactivate;

  const _SubscriptionCard({
    required this.subscription,
    required this.onSuspend,
    required this.onReactivate,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final companyName =
        subscription['companyName']?.toString() ??
            subscription['company']?['name']?.toString() ??
            '';
    final planName =
        subscription['planName']?.toString() ??
            subscription['plan']?['name']?.toString() ??
            '';
    final status = subscription['status']?.toString() ?? '';
    final currency =
        subscription['currency']?.toString() ?? '';
    final employeeCount =
        subscription['employeeCount'] ?? 0;
    final maxEmployees =
        subscription['maxEmployees'] ?? 0;

    final statusColor = status == 'active'
        ? AppColors.secondary
        : status == 'suspended'
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
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.secondary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.card_membership_outlined,
                      color: AppColors.secondary, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        companyName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      Text(
                        planName,
                        style: TextStyle(
                          fontSize: 13,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: statusColor.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    status,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: statusColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            InfoTile(
              title: AppLocalizations.of(
                  context, 'subscription_employees'),
              value: '$employeeCount / $maxEmployees',
            ),
            if (currency.isNotEmpty)
              InfoTile(
                title: AppLocalizations.of(context, 'currency'),
                value: currency,
              ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (status == 'active')
                  TextButton.icon(
                    onPressed: onSuspend,
                    icon: Icon(Icons.pause_circle_outline,
                        size: 18, color: AppColors.error),
                    label: Text(
                      AppLocalizations.of(
                          context, 'suspend_subscription'),
                      style: TextStyle(color: AppColors.error),
                    ),
                  )
                else if (status == 'suspended')
                  TextButton.icon(
                    onPressed: onReactivate,
                    icon: Icon(Icons.play_circle_outline,
                        size: 18, color: AppColors.secondary),
                    label: Text(
                      AppLocalizations.of(
                          context, 'reactivate_subscription'),
                      style: TextStyle(color: AppColors.secondary),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _BillingEventCard extends StatelessWidget {
  final Map<String, dynamic> event;

  const _BillingEventCard({required this.event});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final eventType = event['eventType']?.toString() ??
        event['type']?.toString() ?? '';
    final amount = event['amount'] ?? '';
    final currency =
        event['currency']?.toString() ?? '';
    final createdAt =
        event['createdAt']?.toString() ??
            event['created_at']?.toString() ?? '';
    final description =
        event['description']?.toString() ?? '';

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
                  child: Icon(Icons.receipt_outlined,
                      color: AppColors.accent, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    eventType,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
                if (amount != null && amount.toString() != '0')
                  Text(
                    '$amount $currency',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: AppColors.accent,
                    ),
                  ),
              ],
            ),
            if (description.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                description,
                style: TextStyle(
                    fontSize: 13, color: subtitleColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            if (createdAt.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                createdAt,
                style: TextStyle(
                    fontSize: 11, color: subtitleColor),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
