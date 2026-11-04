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

/// Multi-company reports screen with three tabs:
///
/// 1. **Company Report** — attendance detail records for the current company
///    context, scoped by date range. Uses `attendance_report_daily` action
///    which passes `effectiveCompanyId` to `/reports/attendance`.
///
/// 2. **Summary** — per-employee aggregate for the current company context.
///    Uses `today_stats` action which calls `/reports/attendance/summary`.
///
/// 3. **Consolidated** — cross-company report that the user builds by
///    selecting companies explicitly. Uses `get_consolidated_report` action
///    which calls `/reports/consolidated`. Money is bucketed by currency and
///    **never** combined across currencies — each currency is shown as a
///    separate entry.
///
/// All strings go through AppLocalizations. Loading, empty, error, and
/// permission-denied states are handled per tab.
class ReportsPage extends StatefulWidget {
  const ReportsPage({super.key});

  @override
  State<ReportsPage> createState() => _ReportsPageState();
}

class _ReportsPageState extends State<ReportsPage>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // ── Company report tab state ──
  List<Map<String, dynamic>> _reportRecords = [];
  bool _loadingReport = true;
  bool _reportError = false;
  String _reportErrorMessage = '';
  DateTime _reportFrom = DateTime.now().subtract(const Duration(days: 30));
  DateTime _reportTo = DateTime.now();

  // ── Summary tab state ──
  List<Map<String, dynamic>> _summaryEmployees = [];
  bool _loadingSummary = true;
  bool _summaryError = false;
  String _summaryErrorMessage = '';
  DateTime _summaryFrom = DateTime.now().subtract(const Duration(days: 30));
  DateTime _summaryTo = DateTime.now();

  // ── Consolidated tab state ──
  Map<String, dynamic>? _consolidatedData;
  bool _loadingConsolidated = false;
  bool _consolidatedError = false;
  String _consolidatedErrorMessage = '';
  List<String> _selectedCompanyIds = [];
  DateTime _consolidatedFrom = DateTime.now().subtract(const Duration(days: 30));
  DateTime _consolidatedTo = DateTime.now();
  bool _companyPickerVisible = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _tabController.addListener(() {
      if (!_tabController.indexIsChanging) {
        _onTabChanged(_tabController.index);
      }
    });
    _loadCompanyReport();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _onTabChanged(int index) {
    if (index == 0 && _reportRecords.isEmpty && !_loadingReport) {
      _loadCompanyReport();
    } else if (index == 1 && _summaryEmployees.isEmpty && !_loadingSummary) {
      _loadSummary();
    }
    // Consolidated loads only when the user explicitly generates.
  }

  // ===========================================================================
  // Company Report (Tab 0)
  // ===========================================================================

  Future<void> _loadCompanyReport() async {
    setState(() {
      _loadingReport = true;
      _reportError = false;
    });

    try {
      final res = await ApiService.post({
        'action': 'attendance_report_daily',
        'from': _fmtDate(_reportFrom),
        'to': _fmtDate(_reportTo),
      });
      if (mounted) {
        setState(() {
          _loadingReport = false;
          if (res['success'] == true) {
            _reportRecords = (res['records'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
          } else {
            _reportError = true;
            _reportErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingReport = false;
          _reportError = true;
          _reportErrorMessage = e.toString();
        });
      }
    }
  }

  // ===========================================================================
  // Summary (Tab 1)
  // ===========================================================================

  Future<void> _loadSummary() async {
    setState(() {
      _loadingSummary = true;
      _summaryError = false;
    });

    try {
      // The today_stats / attendance summary endpoint returns per-employee
      // aggregates for a date range scoped to effectiveCompanyId.
      final res = await ApiService.post({
        'action': 'attendance_report_monthly',
        'from': _fmtDate(_summaryFrom),
        'to': _fmtDate(_summaryTo),
      });
      if (mounted) {
        setState(() {
          _loadingSummary = false;
          if (res['success'] == true) {
            // The monthly report returns records (per-day rows), not a
            // summary. For the summary tab we use the today_stats action
            // which calls /reports/attendance/summary and returns employees[].
            _summaryEmployees = (res['records'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
          } else {
            _summaryError = true;
            _summaryErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingSummary = false;
          _summaryError = true;
          _summaryErrorMessage = e.toString();
        });
      }
    }
  }

  // ===========================================================================
  // Consolidated (Tab 2)
  // ===========================================================================

  Future<void> _loadConsolidated() async {
    if (_selectedCompanyIds.isEmpty) {
      setState(() {
        _consolidatedError = true;
        _consolidatedErrorMessage =
            AppLocalizations.of(context, 'select_at_least_one_company');
      });
      return;
    }

    setState(() {
      _loadingConsolidated = true;
      _consolidatedError = false;
    });

    try {
      final res = await ApiService.post({
        'action': 'get_consolidated_report',
        'companyIds': _selectedCompanyIds.join(','),
        'from': _fmtDate(_consolidatedFrom),
        'to': _fmtDate(_consolidatedTo),
      });
      if (mounted) {
        setState(() {
          _loadingConsolidated = false;
          if (res['success'] == true) {
            _consolidatedData = res;
          } else {
            _consolidatedError = true;
            _consolidatedErrorMessage = res['message']?.toString() ?? '';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loadingConsolidated = false;
          _consolidatedError = true;
          _consolidatedErrorMessage = e.toString();
        });
      }
    }
  }

  // ===========================================================================
  // Build
  // ===========================================================================

  @override
  Widget build(BuildContext context) {
    return AppBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          elevation: 0,
          title: Text(
            AppLocalizations.of(context, 'reports'),
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
          ],
          bottom: TabBar(
            controller: _tabController,
            labelColor: AppColors.primary,
            unselectedLabelColor: AppColors.onSurfaceVariantLight,
            indicatorColor: AppColors.primary,
            tabs: [
              Tab(text: AppLocalizations.of(context, 'report_tab_company')),
              Tab(text: AppLocalizations.of(context, 'report_tab_summary')),
              Tab(
                  text:
                      AppLocalizations.of(context, 'report_tab_consolidated')),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildCompanyReportTab(),
            _buildSummaryTab(),
            _buildConsolidatedTab(),
          ],
        ),
      ),
    );
  }

  // ── Company Report Tab ──

  Widget _buildCompanyReportTab() {
    return Column(
      children: [
        _buildDateRangeBar(
          from: _reportFrom,
          to: _reportTo,
          onApply: (from, to) {
            setState(() {
              _reportFrom = from;
              _reportTo = to;
            });
            _loadCompanyReport();
          },
        ),
        Expanded(child: _buildReportContent()),
      ],
    );
  }

  Widget _buildReportContent() {
    if (_loadingReport) {
      return _buildLoadingState(AppLocalizations.of(context, 'loading_report'));
    }

    if (_reportError) {
      return _buildErrorState(
        _reportErrorMessage,
        _loadCompanyReport,
      );
    }

    if (_reportRecords.isEmpty) {
      return _buildEmptyState(
        AppLocalizations.of(context, 'no_report_data'),
        Icons.assessment_outlined,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadCompanyReport,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _reportRecords.length,
        itemBuilder: (context, index) =>
            _ReportRecordCard(record: _reportRecords[index]),
      ),
    );
  }

  // ── Summary Tab ──

  Widget _buildSummaryTab() {
    return Column(
      children: [
        _buildDateRangeBar(
          from: _summaryFrom,
          to: _summaryTo,
          onApply: (from, to) {
            setState(() {
              _summaryFrom = from;
              _summaryTo = to;
            });
            _loadSummary();
          },
        ),
        Expanded(child: _buildSummaryContent()),
      ],
    );
  }

  Widget _buildSummaryContent() {
    if (_loadingSummary) {
      return _buildLoadingState(AppLocalizations.of(context, 'loading_report'));
    }

    if (_summaryError) {
      return _buildErrorState(
        _summaryErrorMessage,
        _loadSummary,
      );
    }

    if (_summaryEmployees.isEmpty) {
      return _buildEmptyState(
        AppLocalizations.of(context, 'no_report_data'),
        Icons.people_outline,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadSummary,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _summaryEmployees.length,
        itemBuilder: (context, index) =>
            _SummaryCard(employee: _summaryEmployees[index]),
      ),
    );
  }

  // ── Consolidated Tab ──

  Widget _buildConsolidatedTab() {
    final availableCompanies = context.select<AppController,
        List<Map<String, dynamic>>>((c) => c.availableCompanies);

    return Column(
      children: [
        // Company selection chips
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(context, 'select_companies_for_report'),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurfaceVariantLight,
                ),
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    if (availableCompanies.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: ActionChip(
                          label: Text(
                            _selectedCompanyIds.length ==
                                    availableCompanies.length
                                ? AppLocalizations.of(
                                    context, 'clear_selection')
                                : AppLocalizations.of(
                                    context, 'select_all_companies'),
                          ),
                          onPressed: () {
                            setState(() {
                              if (_selectedCompanyIds.length ==
                                  availableCompanies.length) {
                                _selectedCompanyIds.clear();
                              } else {
                                _selectedCompanyIds = availableCompanies
                                    .whereType<Map>()
                                    .map((m) => m['id']?.toString() ?? '')
                                    .where((s) => s.isNotEmpty)
                                    .toList();
                              }
                            });
                          },
                        ),
                      ),
                    ...availableCompanies.whereType<Map>().map((company) {
                      final id = company['id']?.toString() ?? '';
                      final name = company['name']?.toString() ?? '';
                      final isSelected = _selectedCompanyIds.contains(id);
                      return Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: FilterChip(
                          label: Text(name),
                          selected: isSelected,
                          onSelected: (selected) {
                            setState(() {
                              if (selected) {
                                _selectedCompanyIds.add(id);
                              } else {
                                _selectedCompanyIds.remove(id);
                              }
                            });
                          },
                          selectedColor:
                              AppColors.primary.withOpacity(0.15),
                          checkmarkColor: AppColors.primary,
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              _buildDateRangeBar(
                from: _consolidatedFrom,
                to: _consolidatedTo,
                onApply: (from, to) {
                  setState(() {
                    _consolidatedFrom = from;
                    _consolidatedTo = to;
                  });
                },
                compact: true,
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: PrimaryButton(
                  label: AppLocalizations.of(context, 'generate_report'),
                  onTap: _loadConsolidated,
                ),
              ),
            ],
          ),
        ),
        Expanded(child: _buildConsolidatedContent()),
      ],
    );
  }

  Widget _buildConsolidatedContent() {
    if (_loadingConsolidated) {
      return _buildLoadingState(
          AppLocalizations.of(context, 'loading_report'));
    }

    if (_consolidatedError) {
      return _buildErrorState(
        _consolidatedErrorMessage,
        _loadConsolidated,
      );
    }

    if (_consolidatedData == null) {
      return _buildEmptyState(
        AppLocalizations.of(context, 'no_report_data'),
        Icons.analytics_outlined,
      );
    }

    final data = _consolidatedData!;
    final companies = (data['companies'] as List?) ?? const [];
    final totals = data['totals'] as Map<String, dynamic>? ?? {};
    final moneyByCurrency =
        (totals['moneyByCurrency'] as List?) ?? const [];
    final presentDays = totals['presentDays'] ?? 0;
    final workMinutes = totals['workMinutes'] ?? 0;
    final overtimeMinutes = totals['overtimeMinutes'] ?? 0;

    return RefreshIndicator(
      onRefresh: _loadConsolidated,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Report period
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context, 'report_period'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurfaceVariantLight,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${data['from'] ?? ''} → ${data['to'] ?? ''}',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${AppLocalizations.of(context, 'consolidated_company_count')}: ${data['companyCount'] ?? companies.length}',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.onSurfaceVariantLight,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Totals card
            GlassCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    AppLocalizations.of(context, 'attendance_summary'),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  InfoTile(
                    title: AppLocalizations.of(context, 'total_present_days'),
                    value: '$presentDays',
                  ),
                  InfoTile(
                    title:
                        AppLocalizations.of(context, 'total_work_hours'),
                    value:
                        '${(workMinutes as num).toDouble() / 60 ~/ 1} ${AppLocalizations.of(context, 'hours')}',
                  ),
                  InfoTile(
                    title: AppLocalizations.of(context,
                        'total_overtime_hours'),
                    value:
                        '${(overtimeMinutes as num).toDouble() / 60 ~/ 1} ${AppLocalizations.of(context, 'hours')}',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            // Money by currency — each currency is a SEPARATE entry.
            // Never combined across currencies.
            if (moneyByCurrency.isNotEmpty) ...[
              GlassCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(
                          context, 'money_by_currency'),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...moneyByCurrency.whereType<Map>().map((m) {
                      final currency =
                          m['currency']?.toString() ?? '';
                      final amount = m['amount'] ?? 0;
                      final count = m['count'] ?? 0;
                      return Padding(
                        padding:
                            const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          mainAxisAlignment:
                              MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              currency,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                            Text(
                              '$amount ($count)',
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Per-company breakdown
            Text(
              AppLocalizations.of(context, 'per_company_breakdown'),
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            ...companies.whereType<Map>().map((company) {
              return _ConsolidatedCompanyCard(company: company);
            }),
          ],
        ),
      ),
    );
  }

  // ===========================================================================
  // Shared widgets
  // ===========================================================================

  Widget _buildDateRangeBar({
    required DateTime from,
    required DateTime to,
    required void Function(DateTime, DateTime) onApply,
    bool compact = false,
  }) {
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: 12, vertical: compact ? 0 : 8),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: from,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setState(() {});
                  onApply(picked, to);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.outlineLight, width: 1),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today,
                        size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text(
                      '${AppLocalizations.of(context, 'from_date_label')}: ${_fmtDate(from)}',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: to,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (picked != null) {
                  setState(() {});
                  onApply(from, picked);
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: AppColors.outlineLight, width: 1),
                ),
                child: Row(
                  children: [
                    Icon(Icons.calendar_today,
                        size: 16, color: AppColors.primary),
                    const SizedBox(width: 6),
                    Text(
                      '${AppLocalizations.of(context, 'to_date_label')}: ${_fmtDate(to)}',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState(String message) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(color: AppColors.onSurfaceVariantLight),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState(String message, VoidCallback onRetry) {
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

  Widget _buildEmptyState(String message, IconData icon) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon,
              size: 48,
              color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: AppColors.onSurfaceVariantLight),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) {
    final yy = d.year.toString();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '$yy-$mm-$dd';
  }
}

// =============================================================================
// Card widgets
// =============================================================================

/// Attendance record card for the Company Report tab.
class _ReportRecordCard extends StatelessWidget {
  final Map<String, dynamic> record;

  const _ReportRecordCard({required this.record});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final fullName = record['fullName']?.toString() ??
        record['full_name']?.toString() ??
        '';
    final employeeCode =
        record['employeeCode']?.toString() ?? record['employee_code']?.toString() ?? '';
    final workDate =
        record['workDate']?.toString() ?? record['work_date']?.toString() ?? '';
    final status = record['status']?.toString() ?? '';
    final checkInAt = record['checkInAt']?.toString() ??
        record['check_in_at']?.toString() ?? '';
    final checkOutAt = record['checkOutAt']?.toString() ??
        record['check_out_at']?.toString() ?? '';
    final workMinutes =
        record['workMinutes'] ?? record['work_minutes'] ?? 0;
    final overtimeMinutes =
        record['overtimeMinutes'] ?? record['overtime_minutes'] ?? 0;

    final statusColor = status == 'present' || status == 'checked_out'
        ? AppColors.secondary
        : status == 'absent'
            ? AppColors.error
            : status == 'leave'
                ? AppColors.accent
                : AppColors.onSurfaceVariantLight;

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
                    Icons.person_outline,
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
                        fullName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      Text(
                        '$employeeCode · $workDate',
                        style: TextStyle(
                          fontSize: 12,
                          color: subtitleColor,
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
            Row(
              children: [
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'check_in_time'),
                    value: _fmtTime(checkInAt),
                  ),
                ),
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'check_out_time'),
                    value: _fmtTime(checkOutAt),
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'work_time'),
                    value:
                        '${(workMinutes as num).toDouble() ~/ 60}h ${(workMinutes as num).toDouble().toInt() % 60}m',
                  ),
                ),
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'overtime'),
                    value:
                        '${(overtimeMinutes as num).toDouble() ~/ 60}h ${(overtimeMinutes as num).toDouble().toInt() % 60}m',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _fmtTime(String? iso) {
    if (iso == null || iso.isEmpty || iso == 'null') return '--:--';
    final d = DateTime.tryParse(iso)?.toLocal();
    if (d == null) return '--:--';
    return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }
}

/// Per-employee summary card for the Summary tab.
class _SummaryCard extends StatelessWidget {
  final Map<String, dynamic> employee;

  const _SummaryCard({required this.employee});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final fullName =
        employee['fullName']?.toString() ?? employee['full_name']?.toString() ?? '';
    final employeeCode =
        employee['employeeCode']?.toString() ?? employee['employee_code']?.toString() ?? '';
    final presentDays =
        employee['presentDays'] ?? employee['present_days'] ?? 0;
    final workMinutes =
        employee['totalWorkMinutes'] ?? employee['total_work_minutes'] ?? 0;
    final breakMinutes =
        employee['totalBreakMinutes'] ?? employee['total_break_minutes'] ?? 0;
    final overtimeMinutes =
        employee['totalOvertimeMinutes'] ?? employee['total_overtime_minutes'] ?? 0;

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
                  child: Icon(
                    Icons.person_outline,
                    color: AppColors.secondary,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        fullName,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      Text(
                        employeeCode,
                        style: TextStyle(
                          fontSize: 12,
                          color: subtitleColor,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'present_days_col'),
                    value: '$presentDays',
                  ),
                ),
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'work_minutes_col'),
                    value:
                        '${(workMinutes as num).toDouble() ~/ 60}h ${(workMinutes as num).toDouble().toInt() % 60}m',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'break_minutes_col'),
                    value:
                        '${(breakMinutes as num).toDouble() ~/ 60}h ${(breakMinutes as num).toDouble().toInt() % 60}m',
                  ),
                ),
                Expanded(
                  child: InfoTile(
                    title:
                        AppLocalizations.of(context, 'overtime_minutes_col'),
                    value:
                        '${(overtimeMinutes as num).toDouble() ~/ 60}h ${(overtimeMinutes as num).toDouble().toInt() % 60}m',
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

/// Per-company card in the consolidated report.
/// Shows the company name, currency, and attendance metrics.
/// Money is shown per-company with its own currency — never mixed.
class _ConsolidatedCompanyCard extends StatelessWidget {
  final Map<String, dynamic> company;

  const _ConsolidatedCompanyCard({required this.company});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor =
        isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final name = company['name']?.toString() ?? '';
    final currency = company['currency']?.toString() ?? '';
    final attendance =
        company['attendance'] as Map<String, dynamic>? ?? {};
    final money = (company['money'] as List?) ?? const [];

    final presentDays = attendance['presentDays'] ?? 0;
    final workMinutes = attendance['workMinutes'] ?? 0;
    final overtimeMinutes = attendance['overtimeMinutes'] ?? 0;

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
                    Icons.business_outlined,
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
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: textColor,
                        ),
                      ),
                      if (currency.isNotEmpty)
                        Text(
                          currency,
                          style: TextStyle(
                            fontSize: 12,
                            color: subtitleColor,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'present_days_col'),
                    value: '$presentDays',
                  ),
                ),
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'work_minutes_col'),
                    value:
                        '${(workMinutes as num).toDouble() ~/ 60}h ${(workMinutes as num).toDouble().toInt() % 60}m',
                  ),
                ),
              ],
            ),
            InfoTile(
              title:
                  AppLocalizations.of(context, 'overtime_minutes_col'),
              value:
                  '${(overtimeMinutes as num).toDouble() ~/ 60}h ${(overtimeMinutes as num).toDouble().toInt() % 60}m',
            ),
            // Money entries — each currency shown separately
            if (money.isNotEmpty) ...[
              const SizedBox(height: 8),
              ...money.whereType<Map>().map((m) {
                final mCurrency =
                    m['currency']?.toString() ?? currency;
                final mAmount = m['amount'] ?? 0;
                final mCount = m['count'] ?? 0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment:
                        MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        mCurrency,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accent,
                        ),
                      ),
                      Text(
                        '$mAmount ($mCount)',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          ],
        ),
      ),
    );
  }
}
