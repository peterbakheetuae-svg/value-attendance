import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/company_selector_sheet.dart';
import '../../services/api_service.dart';

/// KPI management screen — shows KPI definitions for the current company
/// context, allows creating/editing definitions, and viewing evaluations.
///
/// Missing evaluations are NOT displayed as zero — they show as
/// "kpi_pending_evaluation" (pending).
class KpiPage extends StatefulWidget {
  const KpiPage({super.key});

  @override
  State<KpiPage> createState() => _KpiPageState();
}

class _KpiPageState extends State<KpiPage> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  List<Map<String, dynamic>> _definitions = [];
  List<Map<String, dynamic>> _tasks = [];
  bool _loadingDefinitions = true;
  bool _loadingTasks = true;
  bool _error = false;
  String _errorMessage = '';

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
    _loadDefinitions();
    _loadTasks();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadDefinitions() async {
    setState(() => _loadingDefinitions = true);
    try {
      final res = await ApiService.post({'action': 'get_kpi_definitions'});
      if (mounted) {
        setState(() {
          _loadingDefinitions = false;
          if (res['success'] == true) {
            _definitions = (res['definitions'] as List?)
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
          _loadingDefinitions = false;
          _error = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  Future<void> _loadTasks() async {
    setState(() => _loadingTasks = true);
    try {
      final res = await ApiService.post({'action': 'get_kpi_tasks'});
      if (mounted) {
        setState(() {
          _loadingTasks = false;
          if (res['success'] == true) {
            _tasks = (res['tasks'] as List?)
                    ?.whereType<Map>()
                    .map((m) => m.cast<String, dynamic>())
                    .toList() ??
                [];
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loadingTasks = false);
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
            AppLocalizations.of(context, 'kpi_definitions'),
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
            tabs: [
              Tab(text: AppLocalizations.of(context, 'kpi_definitions')),
              Tab(text: AppLocalizations.of(context, 'kpi_tasks')),
              Tab(text: AppLocalizations.of(context, 'kpi_monthly')),
            ],
          ),
        ),
        body: TabBarView(
          controller: _tabController,
          children: [
            _buildDefinitionsTab(),
            _buildTasksTab(),
            _buildMonthlyTab(),
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showAddKpiDialog(),
          backgroundColor: AppColors.primary,
          child: const Icon(Icons.add, color: Colors.white),
        ),
      ),
    );
  }

  Widget _buildDefinitionsTab() {
    if (_loadingDefinitions) {
      return Center(child: CircularProgressIndicator());
    }

    if (_definitions.isEmpty) {
      return _EmptyState(
        icon: Icons.assessment_outlined,
        message: AppLocalizations.of(context, 'kpi_no_data'),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDefinitions,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _definitions.length,
        itemBuilder: (context, index) {
          final def = _definitions[index];
          return _KpiDefinitionCard(
            definition: def,
            onEdit: () => _showEditKpiDialog(def),
          );
        },
      ),
    );
  }

  Widget _buildTasksTab() {
    if (_loadingTasks) {
      return Center(child: CircularProgressIndicator());
    }

    if (_tasks.isEmpty) {
      return _EmptyState(
        icon: Icons.task_alt,
        message: AppLocalizations.of(context, 'kpi_no_data'),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadTasks,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _tasks.length,
        itemBuilder: (context, index) {
          final task = _tasks[index];
          return _KpiTaskCard(task: task);
        },
      ),
    );
  }

  Widget _buildMonthlyTab() {
    return _MonthlyKpiView();
  }

  void _showAddKpiDialog() {
    _showKpiFormDialog(definition: null);
  }

  void _showEditKpiDialog(Map<String, dynamic> def) {
    _showKpiFormDialog(definition: def);
  }

  void _showKpiFormDialog({Map<String, dynamic>? definition}) {
    final isEdit = definition != null;
    final keyController =
        TextEditingController(text: definition?['key']?.toString() ?? '');
    final nameController =
        TextEditingController(text: definition?['name']?.toString() ?? '');
    final unitController =
        TextEditingController(text: definition?['unit']?.toString() ?? '');
    final minController = TextEditingController(
        text: definition?['minScore']?.toString() ?? '0');
    final maxController = TextEditingController(
        text: definition?['maxScore']?.toString() ?? '100');

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          isEdit
              ? AppLocalizations.of(dialogContext, 'edit_kpi')
              : AppLocalizations.of(dialogContext, 'add_kpi'),
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'kpi_key'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: nameController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'kpi_name'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: unitController,
                decoration: InputDecoration(
                  labelText: AppLocalizations.of(dialogContext, 'kpi_unit'),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: minController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(
                            dialogContext, 'kpi_min_score'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: maxController,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(
                        labelText: AppLocalizations.of(
                            dialogContext, 'kpi_max_score'),
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  ),
                ],
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
                'action': isEdit ? 'update_kpi_definition' : 'add_kpi_definition',
                'key': keyController.text.trim(),
                'name': nameController.text.trim(),
                'unit': unitController.text.trim(),
                'minScore': double.tryParse(minController.text) ?? 0,
                'maxScore': double.tryParse(maxController.text) ?? 100,
              };
              if (isEdit) {
                payload['id'] = definition!['id']?.toString() ?? '';
              }

              final res = await ApiService.post(payload);
              if (dialogContext.mounted) {
                Navigator.of(dialogContext).pop();
                if (res['success'] == true) {
                  _loadDefinitions();
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

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;

  const _EmptyState({required this.icon, required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 48, color: AppColors.onSurfaceVariantLight.withOpacity(0.5)),
          const SizedBox(height: 12),
          Text(
            message,
            style: TextStyle(color: AppColors.onSurfaceVariantLight),
          ),
        ],
      ),
    );
  }
}

class _KpiDefinitionCard extends StatelessWidget {
  final Map<String, dynamic> definition;
  final VoidCallback onEdit;

  const _KpiDefinitionCard({
    required this.definition,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final name = definition['name']?.toString() ?? '';
    final key = definition['key']?.toString() ?? '';
    final unit = definition['unit']?.toString() ?? '';
    final minScore = definition['minScore']?.toString() ?? '0';
    final maxScore = definition['maxScore']?.toString() ?? '100';
    final isActive = definition['isActive'] == true;

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
                    color: AppColors.primary.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.assessment, color: AppColors.primary, size: 20),
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
                          fontWeight: FontWeight.w600,
                          color: textColor,
                        ),
                      ),
                      Text(
                        key,
                        style: TextStyle(fontSize: 12, color: subtitleColor),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isActive
                        ? AppColors.secondary.withOpacity(0.15)
                        : AppColors.onSurfaceVariantLight.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    isActive
                        ? AppLocalizations.of(context, 'kpi_active')
                        : AppLocalizations.of(context, 'kpi_inactive'),
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: isActive ? AppColors.secondary : subtitleColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (unit.isNotEmpty)
                  Expanded(
                    child: InfoTile(
                      title: AppLocalizations.of(context, 'kpi_unit'),
                      value: unit,
                    ),
                  ),
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'kpi_min_score'),
                    value: minScore,
                  ),
                ),
                Expanded(
                  child: InfoTile(
                    title: AppLocalizations.of(context, 'kpi_max_score'),
                    value: maxScore,
                  ),
                ),
              ],
            ),
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

class _KpiTaskCard extends StatelessWidget {
  final Map<String, dynamic> task;

  const _KpiTaskCard({required this.task});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final subtitleColor = isDark
        ? AppColors.onSurfaceVariantDark
        : AppColors.onSurfaceVariantLight;

    final workDate = task['workDate']?.toString() ?? '';
    final state = task['state']?.toString() ?? '';
    final score = task['score'];
    final weight = task['weightPercent']?.toString() ?? '';

    // Missing evaluations are NOT displayed as zero — they show as pending.
    final scoreText = (score == null)
        ? AppLocalizations.of(context, 'kpi_pending_evaluation')
        : score.toString();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.task_alt, color: AppColors.primary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    workDate,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: textColor,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            InfoTile(
              title: AppLocalizations.of(context, 'kpi_score'),
              value: scoreText,
            ),
            if (weight.isNotEmpty)
              InfoTile(
                title: AppLocalizations.of(context, 'kpi_weight'),
                value: '$weight%',
              ),
            InfoTile(
              title: AppLocalizations.of(context, 'status'),
              value: state,
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthlyKpiView extends StatefulWidget {
  @override
  State<_MonthlyKpiView> createState() => _MonthlyKpiViewState();
}

class _MonthlyKpiViewState extends State<_MonthlyKpiView> {
  Map<String, dynamic>? _summary;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _loadMonthly();
  }

  Future<void> _loadMonthly() async {
    setState(() => _loading = true);
    try {
      final now = DateTime.now();
      final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final res = await ApiService.post({
        'action': 'get_kpi_monthly',
        'month': month,
      });
      if (mounted) {
        setState(() {
          _loading = false;
          if (res['success'] == true) {
            _summary = res;
          } else {
            _error = true;
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: CircularProgressIndicator());

    if (_error || _summary == null) {
      return _EmptyState(
        icon: Icons.calendar_month,
        message: AppLocalizations.of(context, 'kpi_no_data'),
      );
    }

    final data = (_summary!['data'] as Map?)?.cast<String, dynamic>() ?? {};
    final items = (data['items'] as List?) ?? [];

    if (items.isEmpty) {
      return _EmptyState(
        icon: Icons.calendar_month,
        message: AppLocalizations.of(context, 'kpi_no_data'),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadMonthly,
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = (items[index] as Map).cast<String, dynamic>();
          return _MonthlyKpiCard(item: item);
        },
      ),
    );
  }
}

class _MonthlyKpiCard extends StatelessWidget {
  final Map<String, dynamic> item;

  const _MonthlyKpiCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final isDark = context.select<AppController, bool>((c) => c.isDark);
    final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;

    final name = item['kpiName']?.toString() ?? item['name']?.toString() ?? '';
    final avgScore = item['avgScore'] ?? item['averageScore'];

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: textColor,
              ),
            ),
            const SizedBox(height: 8),
            InfoTile(
              title: AppLocalizations.of(context, 'kpi_score'),
              value: avgScore?.toString() ??
                  AppLocalizations.of(context, 'kpi_pending_evaluation'),
            ),
          ],
        ),
      ),
    );
  }
}
