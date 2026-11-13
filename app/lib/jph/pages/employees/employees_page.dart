import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../services/employees_api.dart';
import '../../services/api_service.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import 'employee_details_page.dart';
import 'add_employee_page.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/jph_form_ui.dart';
import '../../widgets/glass_bottom_nav.dart'; // سنحتاج لإنشاء هذه الصفحة لاحقاً
import '../../widgets/glass_dialog.dart';
import '../../widgets/glass_ui.dart';

class EmployeesPage extends StatefulWidget {
  final String currentUserId;
  final String currentUserName;
  final String currentUserRole;

  const EmployeesPage({
    super.key,
    required this.currentUserId,
    required this.currentUserName,
    required this.currentUserRole,
  });

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeesPageState extends State<EmployeesPage> {
  List<Map<String, dynamic>> _employees = [];
  bool _loading = true;
  String _searchQuery = '';
  String _selectedFilter = 'الكل'; // قيمة افتراضية للفلتر

  // قائمة خيارات الفلتر
  // الوظائف بتيجي من السيرفر (أي وظيفة جديدة بتظهر هنا لوحدها)
  List<String> _filterOptions = ['الكل', 'نشط', 'غير نشط'];

  Future<void> _loadPositions() async {
    final r = await ApiService.post({'action': 'get_positions'});
    if (!mounted || r['success'] != true) return;
    final names = ((r['positions'] as List?) ?? const []).whereType<Map>().map((m) => '${m['name_ar']}').toList();
    setState(() => _filterOptions = ['الكل', ...names, 'نشط', 'غير نشط']);
  }

  @override
  void initState() {
    super.initState();
    _loadEmployees();
    _loadPositions();
  }

  Future<void> _loadEmployees() async {
    try {
      setState(() {
        _loading = true;
      });

      final response = await EmployeesApi.getAllEmployees();

      if (response["success"] == true && mounted) {
        setState(() {
          _employees = List<Map<String, dynamic>>.from(response["employees"] ?? []);
          _loading = false;
        });
      } else {
        setState(() {
          _loading = false;
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(response["message"] ?? "فشل في تحميل بيانات الموظفين"),
              backgroundColor: Ar.red,
            ),
          );
        }
      }
    } catch (e) {
      setState(() {
        _loading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("خطأ في الاتصال: $e"),
            backgroundColor: Ar.red,
          ),
        );
      }
    }
  }

  // دالة للفلتر والبحث
  List<Map<String, dynamic>> get _filteredEmployees {
    List<Map<String, dynamic>> filtered = _employees;

    // تطبيق الفلتر حسب الدور أو الحالة
    if (_selectedFilter != 'الكل') {
      if (_selectedFilter == 'نشط') {
        filtered = filtered.where((employee) => employee['active'] == true).toList();
      } else if (_selectedFilter == 'غير نشط') {
        filtered = filtered.where((employee) => employee['active'] == false).toList();
      } else {
        filtered = filtered.where((employee) => (employee['position'] ?? employee['role']) == _selectedFilter).toList();
      }
    }

    // تطبيق البحث إذا كان هناك نص للبحث
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((employee) {
        final name = employee['name']?.toString().toLowerCase() ?? '';
        final uid = employee['uid']?.toString().toLowerCase() ?? '';
        final role = (employee['position'] ?? employee['role'])?.toString().toLowerCase() ?? '';
        final phone = employee['phone']?.toString().toLowerCase() ?? '';
        final email = employee['email']?.toString().toLowerCase() ?? '';

        final query = _searchQuery.toLowerCase();
        return name.contains(query) ||
            uid.contains(query) ||
            role.contains(query) ||
            phone.contains(query) ||
            email.contains(query);
      }).toList();
    }

    return filtered;
  }

  IconData _getStatusIcon(String? status) {
    switch(status) {
      case 'على رأس العمل':
        return Icons.work;
      case 'تم التصفيه':
        return Icons.check_circle;
      case 'مغادر':
        return Icons.exit_to_app;
      case 'إجازة':
        return Icons.beach_access;
      default:
        return Icons.help;
    }
  }

  Color _getStatusColor(String? status, bool isDark) {
    switch(status) {
      case 'على رأس العمل':
        return isDark ? Ar.green[300]! : Ar.green;
      case 'تم التصفيه':
        return isDark ? Ar.info[300]! : Ar.info;
      case 'مغادر':
        return isDark ? Ar.red[300]! : Ar.red;
      case 'إجازة':
        return isDark ? Ar.amber[300]! : Ar.amber;
      default:
        return isDark ? Ar.grey[300]! : Ar.grey;
    }
  }

  void _showChangeStatusDialog(Map<String, dynamic> employee, bool isDark) {
    final List<String> statuses = [
      'على رأس العمل',
      'تم التصفيه',
      'مغادر',
      'إجازة'
    ];

    showDialog(
      context: context,
      builder: (context) {
        return GlassAlertDialog(
          backgroundColor: isDark ? Ar.grey[900] : Colors.white,
          title: Text(
            'تغيير وضع الموظف',
            style: TextStyle(
              color: isDark ? Colors.white : Colors.black,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: statuses.map((status) {
              return ListTile(
                leading: Icon(
                  _getStatusIcon(status),
                  color: _getStatusColor(status, isDark),
                ),
                title: Text(
                  status,
                  style: TextStyle(
                    color: isDark ? Colors.white : Colors.black,
                  ),
                ),
                onTap: () async {
                  Navigator.pop(context);
                  await _changeEmployeeWorkStatus(
                    uid: employee['uid']?.toString() ?? '',
                    status: status,
                    employeeName: employee['name']?.toString() ?? '',
                  );
                },
              );
            }).toList(),
          ),
        );
      },
    );
  }

  Future<void> _changeEmployeeWorkStatus({
    required String uid,
    required String status,
    required String employeeName,
  }) async {
    try {
      final response = await EmployeesApi.changeEmployeeWorkStatus(
        uid: uid,
        status: status,
      );

      if (response["success"] == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم تغيير وضع $employeeName إلى "$status"'),
            backgroundColor: Ar.green,
          ),
        );
        await _loadEmployees();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response["message"] ?? 'فشل في تغيير الوضع'),
            backgroundColor: Ar.red,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('خطأ في تغيير الوضع: $e'),
            backgroundColor: Ar.red,
          ),
        );
      }
    }
  }

  // دالة للانتقال إلى صفحة إضافة موظف جديد
  void _navigateToAddEmployee() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddEmployeePage(
          currentUserId: widget.currentUserId,
          currentUserName: widget.currentUserName,
          currentUserRole: widget.currentUserRole,
          onEmployeeAdded: _loadEmployees,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                bottom: false,
                child: Column(
                  children: [
                    // ✅ Header يدوي بدل AppBar
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          IconButton(
                            icon: Icon(
                              Icons.arrow_back,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              AppLocalizations.of(context, 'employees') ?? 'الموظفين',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                          ),
                          // زر إضافة موظف جديد بدلاً من زر التحديث
                          IconButton(
                            icon: Icon(
                              Icons.person_add,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            onPressed: _navigateToAddEmployee,
                          ),
                          // زر التحديث يبقى ولكن في مكان آخر (مثل سحب للتحديث أو زر منفصل)
                          IconButton(
                            icon: Icon(
                              Icons.refresh,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            onPressed: _loadEmployees,
                          ),
                        ],
                      ),
                    ),

                    // شريط البحث والفلتر
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: [
                          // شريط البحث
                          TextField(
                            decoration: InputDecoration(
                              hintText: AppLocalizations.of(context, 'search_employees') ?? 'ابحث عن موظف',
                              prefixIcon: Icon(Icons.search),
                              filled: true,
                              fillColor: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 14,
                              ),
                            ),
                            onChanged: (value) {
                              setState(() {
                                _searchQuery = value;
                              });
                            },
                          ),

                          const SizedBox(height: 12),

                          // قائمة الفلتر — نفس شكل باقي القوائم في التطبيق
                          JphUi.picker(
                            isDark: isDark,
                            icon: Icons.filter_list_rounded,
                            iconColor: Ar.green,
                            label: 'فلتر',
                            value: _selectedFilter,
                            onTap: () async {
                              final v = await JphUi.sheet<String>(context, isDark, 'فلتر الموظفين', [
                                for (final o in _filterOptions)
                                  (o, o, o == 'الكل' ? Icons.groups_rounded : o == 'نشط' ? Icons.check_circle_outline_rounded
                                      : o == 'غير نشط' ? Icons.person_off_outlined : Icons.work_outline_rounded),
                              ], selected: _selectedFilter, icon: Icons.filter_list_rounded);
                              if (v != null) setState(() => _selectedFilter = v);
                            },
                          ),
                        ],
                      ),
                    ),

                    // إحصائيات
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'إجمالي الموظفين',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: isDark ? Colors.white70 : Ar.grey[700],
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '${_filteredEmployees.length} موظف',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                              ),
                            ],
                          ),

                          // إحصائيات إضافية
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                'نشط: ${_employees.where((e) => e['active'] == true).length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Ar.green[300] : Ar.green,
                                ),
                              ),
                              Text(
                                'غير نشط: ${_employees.where((e) => e['active'] == false).length}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: isDark ? Ar.red[300] : Ar.red,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 8),

                    // قائمة الموظفين
                    Expanded(
                      child: _loading
                          ? Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      )
                          : _filteredEmployees.isEmpty
                          ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.group_off,
                              size: 64,
                              color: isDark ? Colors.white30 : Ar.grey[400],
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _searchQuery.isEmpty && _selectedFilter == 'الكل'
                                  ? AppLocalizations.of(context, 'no_employees_found') ?? 'لا يوجد موظفين'
                                  : AppLocalizations.of(context, 'no_results') ?? 'لا توجد نتائج',
                              style: TextStyle(
                                fontSize: 16,
                                color: isDark ? Colors.white70 : Ar.grey[600],
                              ),
                            ),
                            if (_searchQuery.isNotEmpty || _selectedFilter != 'الكل')
                              TextButton(
                                onPressed: () {
                                  setState(() {
                                    _searchQuery = '';
                                    _selectedFilter = 'الكل';
                                  });
                                },
                                child: Text(
                                  'عرض جميع الموظفين',
                                  style: TextStyle(
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      )
                          : RefreshIndicator(
                        onRefresh: _loadEmployees,
                        color: AppColors.primary,
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 120),
                          itemCount: _filteredEmployees.length,
                          itemBuilder: (context, index) {
                            final employee = _filteredEmployees[index];
                            return _buildEmployeeCard(employee, isDark);
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // شريط التنقل زي باقي الصفحات — المحتوى بيعدّي تحته
              extendBody: true,
              bottomNavigationBar: GlassBottomNav(
                currentIndex: 2,
                onTap: (index) => AppNav.go(context, index, current: 2, uid: widget.currentUserId,
                    name: widget.currentUserName, role: widget.currentUserRole),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmployeeCard(Map<String, dynamic> employee, bool isDark) {
    final uid = employee['uid']?.toString() ?? '';
    final name = employee['name']?.toString() ?? 'غير معروف';
    final role = (employee['position'] ?? employee['role'])?.toString() ?? 'غير محدد';
    final active = employee['active'] == true;
    final photo = employee['photo']?.toString() ?? '';
    final dailyRate = employee['dailyRate']?.toString() ?? '0';
    final salary = employee['salary']?.toString() ?? '0';
    final phone = employee['phone']?.toString() ?? '';
    final email = employee['email']?.toString() ?? '';
    final status = employee['status']?.toString() ?? '';
    final level = employee['level']?.toString() ?? '';

    return GestureDetector(
      onTap: () async {
        final result = await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => EmployeeDetailsPage(
              employeeData: employee,
              currentUserId: widget.currentUserId,
              currentUserName: widget.currentUserName,
              currentUserRole: widget.currentUserRole,
            ),
          ),
        );

        if (result == true) {
          await _loadEmployees();
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // صورة الموظف
              _buildEmployeeAvatar(photo, name, isDark, active),

              const SizedBox(width: 16),

              // بيانات الموظف
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Text(
                            name,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: active
                                ? (isDark ? Ar.green.withOpacity(0.2) : Ar.green.withOpacity(0.1))
                                : (isDark ? Ar.red.withOpacity(0.2) : Ar.red.withOpacity(0.1)),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            active ? 'نشط' : 'غير نشط',
                            style: TextStyle(
                              fontSize: 12,
                              color: active
                                  ? (isDark ? Ar.green[300] : Ar.green[800])
                                  : (isDark ? Ar.red[300] : Ar.red[800]),
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 4),

                    Row(
                      children: [
                        Icon(
                          Icons.work,
                          size: 14,
                          color: isDark ? Colors.white70 : Ar.grey[600],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          role,
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white70 : Ar.grey[700],
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // حالة العمل (الوضع)
                    if (status.isNotEmpty)
                      Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _getStatusColor(status, isDark).withOpacity(isDark ? 0.2 : 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: _getStatusColor(status, isDark).withOpacity(0.3),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(_getStatusIcon(status), size: 14, color: _getStatusColor(status, isDark)),
                            const SizedBox(width: 4),
                            Text(
                              status,
                              style: TextStyle(
                                fontSize: 12,
                                color: _getStatusColor(status, isDark),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),

                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (phone.isNotEmpty)
                          _buildInfoChip(
                            icon: Icons.phone,
                            text: phone,
                            color: isDark ? Ar.info[300]! : Ar.info,
                            isDark: isDark,
                          ),

                        if (email.isNotEmpty)
                          _buildInfoChip(
                            icon: Icons.email,
                            text: email.length > 20 ? '${email.substring(0, 20)}...' : email,
                            color: isDark ? Ar.green[300]! : Ar.green,
                            isDark: isDark,
                          ),

                        if (level.isNotEmpty)
                          _buildInfoChip(
                            icon: Icons.star,
                            text: 'مستوى $level',
                            color: isDark ? Ar.accent[300]! : Ar.accent,
                            isDark: isDark,
                          ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    Row(
                      children: [
                        Icon(
                          Icons.badge,
                          size: 12,
                          color: isDark ? Colors.white60 : Ar.grey[600],
                        ),
                        const SizedBox(width: 4),
                        Text(
                          'ID: $uid',
                          style: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white60 : Ar.grey[600],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // أزرار التحكم
              Column(
                children: [
                  // زر تغيير الوضع - يظهر فقط إذا لم يكن المالك
                  if (role != 'المالك')
                    IconButton(
                      icon: Icon(
                        _getStatusIcon(status),
                        color: _getStatusColor(status, isDark),
                        size: 20,
                      ),
                      onPressed: () {
                        _showChangeStatusDialog(employee, isDark);
                      },
                    ),

                  // زر التعديل - يظهر فقط إذا لم يكن المالك
                  if (role != 'المالك')
                    IconButton(
                      icon: Icon(
                        Icons.edit,
                        color: isDark ? AppColors.primaryLight : AppColors.primary,
                        size: 20,
                      ),
                      onPressed: () async {
                        final result = await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => EmployeeDetailsPage(
                              employeeData: employee,
                              currentUserId: widget.currentUserId,
                              currentUserName: widget.currentUserName,
                              currentUserRole: widget.currentUserRole,
                            ),
                          ),
                        );

                        if (result == true) {
                          await _loadEmployees();
                        }
                      },
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmployeeAvatar(String photo, String name, bool isDark, bool active) {
    return Stack(
      children: [
        Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey[200],
            border: Border.all(
              color: active
                  ? (isDark ? Ar.green.withOpacity(0.3) : Ar.green.withOpacity(0.3))
                  : (isDark ? Ar.red.withOpacity(0.3) : Ar.red.withOpacity(0.3)),
              width: 2,
            ),
          ),
          child: ClipOval(
            child: photo.isNotEmpty
                ? Image.network(
              photo,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Center(
                  child: CircularProgressIndicator(
                    value: loadingProgress.expectedTotalBytes != null
                        ? loadingProgress.cumulativeBytesLoaded /
                        loadingProgress.expectedTotalBytes!
                        : null,
                    strokeWidth: 2,
                  ),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                return Center(
                  child: Text(
                    name.isNotEmpty ? name[0] : '?',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: isDark ? Colors.white70 : Ar.grey[700],
                    ),
                  ),
                );
              },
            )
                : Center(
              child: Text(
                name.isNotEmpty ? name[0] : '?',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: isDark ? Colors.white70 : Ar.grey[700],
                ),
              ),
            ),
          ),
        ),

        // نقطة الحالة
        Positioned(
          bottom: 2,
          right: 2,
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: active ? Ar.green : Ar.red,
              shape: BoxShape.circle,
              border: Border.all(
                color: isDark ? Colors.black : Colors.white,
                width: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoChip({
    required IconData icon,
    required String text,
    required Color color,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withOpacity(isDark ? 0.2 : 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: color.withOpacity(0.3),
          width: 1,
        ),
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