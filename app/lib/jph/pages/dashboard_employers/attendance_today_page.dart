import 'package:flutter/material.dart';
import '../../services/api_service.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';

class AttendanceTodayPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  /// present · late · absent
  final String filter;

  const AttendanceTodayPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
    this.filter = 'present',
  });

  @override
  State<AttendanceTodayPage> createState() => _AttendanceTodayPageState();
}

class _AttendanceTodayPageState extends State<AttendanceTodayPage> {
  List<Map<String, dynamic>> _attendanceList = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadAttendanceData();
  }

  Future<void> _loadAttendanceData() async {
    try {
      final res = await ApiService.post({'action': 'get_today_attendance', 'filter': widget.filter});
      if (!mounted) return;
      setState(() {
        _attendanceList = List<Map<String, dynamic>>.from(res['employees'] ?? const []);
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
                  switch (widget.filter) { 'absent' => 'الغايبين النهارده', 'late' => 'المتأخرين النهارده', _ => AppLocalizations.of(context, 'today_attendance') },
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
                  : _attendanceList.isEmpty
                  ? Center(
                child: Text(
                  AppLocalizations.of(context, 'no_attendance_today'),
                  style: TextStyle(
                    color: isDark ? Colors.white70 : Colors.grey,
                  ),
                ),
              )
                  : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _attendanceList.length,
                itemBuilder: (context, index) {
                  final employee = _attendanceList[index];
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
              color: isDark ? Colors.blue.withOpacity(0.2) : Colors.blue[100],
            ),
            child: Center(
              child: Text(
                employee['name'].toString().split(' ').map((e) => e[0]).join(),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white : Colors.blue[800],
                ),
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
                if (widget.filter != 'absent') const SizedBox(height: 8),
                if (widget.filter != 'absent') Row(
                  children: [
                    _buildTimeChip(
                      'الحضور: ${employee['checkIn']}',
                      isDark ? Colors.green[300]! : Colors.green,
                    ),
                    const SizedBox(width: 8),
                    _buildTimeChip(
                      'الانصراف: ${employee['checkOut']}',
                      isDark ? Colors.orange[300]! : Colors.orange,
                    ),
                  ],
                ),
              ],
            ),
          ),
          // the chip follows the list that was opened (حاضر / متأخر / غائب)
          Builder(builder: (_) {
            final (label, MaterialColor c) = switch (widget.filter) {
              'absent' => ('غائب', Colors.red),
              'late' => ('متأخر', Colors.orange),
              _ => ('حاضر', Colors.green),
            };
            return Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: isDark ? c.withOpacity(0.2) : c[100],
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(label, style: TextStyle(color: isDark ? c[300] : c[800], fontWeight: FontWeight.bold)),
            );
          }),
        ],
      ),
    );
  }

  Widget _buildTimeChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          color: color,
        ),
      ),
    );
  }
}