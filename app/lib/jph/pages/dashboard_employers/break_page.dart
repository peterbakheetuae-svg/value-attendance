import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';

class BreakPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const BreakPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<BreakPage> createState() => _BreakPageState();
}

class _BreakPageState extends State<BreakPage> {
  List<Map<String, dynamic>> _breakList = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadBreakData();
  }

  Future<void> _loadBreakData() async {
    try {
      final res = await ApiService.post({'action': 'get_break_employees'});
      if (!mounted) return;
      setState(() {
        _breakList = List<Map<String, dynamic>>.from(res['employees'] ?? const []);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;

        return AppBackground(
          child: Directionality(
            textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              appBar: AppBar(
                backgroundColor: Colors.transparent,
                elevation: 0,
                leading: IconButton(
                  icon: Icon(
                    Icons.arrow_back,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                  onPressed: () => Navigator.pop(context),
                ),
                title: Text(
                  AppLocalizations.of(context, 'employees_on_break'),
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
              ),
              body: _loading
                  ? Center(
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                ),
              )
                  : _breakList.isEmpty
                  ? Center(
                child: Text(
                  AppLocalizations.of(context, 'no_employees_on_break'),
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.grey,
                  ),
                ),
              )
                  : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _breakList.length,
                itemBuilder: (context, index) {
                  final employee = _breakList[index];
                  return _buildEmployeeCard(employee, isDark);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmployeeCard(Map<String, dynamic> employee, bool isDark) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.1) : Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: isDark ? Colors.orange.withOpacity(0.2) : Colors.orange[100],
            ),
            child: const Center(
              child: Icon(
                Icons.coffee,
                color: Colors.orange,
                size: 24,
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  employee['name'],
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  employee['project'],
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.grey[700],
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    _buildInfoChip(
                      'بداية: ${employee['breakStart']}',
                      Icons.access_time,
                      isDark ? Colors.blue[300]! : Colors.blue,
                    ),
                    const SizedBox(width: 8),
                    _buildInfoChip(
                      'المدة: ${employee['breakDuration']}',
                      Icons.timer,
                      isDark ? Colors.purple[300]! : Colors.purple,
                    ),
                  ],
                ),
              ],
            ),
          ),
          Column(
            children: [
              Icon(
                Icons.warning,
                color: employee['breakDuration'] == '55 دقيقة'
                    ? Colors.red
                    : isDark ? Colors.green[300] : Colors.green,
              ),
              const SizedBox(height: 4),
              Text(
                employee['breakDuration'] == '55 دقيقة' ? 'مقارب' : 'طبيعي',
                style: TextStyle(
                  fontSize: 12,
                  color: employee['breakDuration'] == '55 دقيقة'
                      ? Colors.red
                      : isDark ? Colors.green[300] : Colors.green,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInfoChip(String text, IconData icon, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}