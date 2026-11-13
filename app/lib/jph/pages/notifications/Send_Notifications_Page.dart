import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import '../../services/app_controller.dart';
import '../../services/send_notification_api.dart';
import '../../services/employees_api.dart';
import '../../widgets/app_background.dart';
import '../../theme/app_colors.dart';
import 'View_Notifications_Page.dart';
import '../../widgets/glass_ui.dart';

class SendNotificationsPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const SendNotificationsPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<SendNotificationsPage> createState() => _SendNotificationsPageState();
}

class _SendNotificationsPageState extends State<SendNotificationsPage> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _titleController = TextEditingController();
  final TextEditingController _contentController = TextEditingController();

  // قائمة الفئات الرئيسية
  final List<String> _categories = [
    'CEO',
    'Managers',
    'Accountants',
    'Employees',
    'الجميع'
  ];

  final Map<String, String> _categoryLabels = {
    'CEO': 'المالك',
    'Managers': 'المديرين',
    'Accountants': 'المحاسبين',
    'Employees': 'الموظفين',
    'الجميع': 'الجميع'
  };

  String _selectedCategory = 'الجميع';
  List<Map<String, dynamic>> _employees = [];
  List<String> _selectedEmployeeIds = [];
  List<String> _selectedEmployeeNames = [];
  bool _isLoading = false;
  bool _isSending = false;

  @override
  void initState() {
    super.initState();
    _loadEmployees();
  }

  Future<void> _loadEmployees() async {
    setState(() => _isLoading = true);
    try {
      final result = await EmployeesApi.getAllEmployees();
      if (result["success"] == true) {
        setState(() {
          _employees = List<Map<String, dynamic>>.from(result["employees"] ?? []);
        });
      } else {
        _showErrorSnackbar(result["message"] ?? "فشل في تحميل الموظفين");
      }
    } catch (e) {
      _showErrorSnackbar("حدث خطأ أثناء تحميل الموظفين: $e");
    } finally {
      setState(() => _isLoading = false);
    }
  }

  // تصفية الموظفين حسب الفئة
  List<Map<String, dynamic>> _getFilteredEmployees() {
    if (_selectedCategory == 'الجميع') return _employees;

    return _employees.where((employee) {
      final role = employee['role']?.toString().toLowerCase() ?? '';
      switch (_selectedCategory) {
        case 'CEO':
          return role.contains('ceo') || role.contains('المالك');
        case 'Managers':
          return role.contains('مدير');
        case 'Accountants':
          return role.contains('accountant') || role.contains('محاسب');
        case 'Employees':
          return role.contains('employee') ||
              role.contains('موظف') ||
              role.contains('مستشار') ||
              (!role.contains('ceo') &&
                  !role.contains('المالك') &&
                  !role.contains('مدير') &&
                  !role.contains('accountant') &&
                  !role.contains('محاسب'));
        default:
          return true;
      }
    }).toList();
  }

  void _toggleEmployee(String uid, String name) {
    setState(() {
      if (_selectedEmployeeIds.contains(uid)) {
        _selectedEmployeeIds.remove(uid);
        _selectedEmployeeNames.remove(name);
      } else {
        _selectedEmployeeIds.add(uid);
        _selectedEmployeeNames.add(name);
      }
    });
  }

  void _selectAllEmployees() {
    final filtered = _getFilteredEmployees();
    setState(() {
      if (_selectedEmployeeIds.length == filtered.length) {
        // إذا كانت كلهم مختارين، إلغاء التحديد
        _selectedEmployeeIds.clear();
        _selectedEmployeeNames.clear();
      } else {
        // تحديد الجميع
        _selectedEmployeeIds = filtered.map((e) => e['uid'].toString()).toList();
        _selectedEmployeeNames = filtered.map((e) => e['name'].toString()).toList();
      }
    });
  }

  Future<void> _sendNotification() async {
    if (!_formKey.currentState!.validate()) return;

    if (_selectedCategory != 'الجميع' && _selectedEmployeeIds.isEmpty) {
      _showErrorSnackbar('يرجى اختيار مستلم واحد على الأقل');
      return;
    }

    setState(() => _isSending = true);

    try {
      // إعداد بيانات الإرسال
      final recipients = _selectedCategory == 'الجميع'
          ? ['الجميع']
          : _selectedEmployeeIds;

      final result = await NotificationApi.sendNotification(
        senderId: widget.uid,
        senderName: widget.name,
        recipients: recipients,
        category: _selectedCategory,
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
      );

      if (result["success"] == true) {
        _showSuccessSnackbar('تم إرسال الإشعار بنجاح');

        // إعادة تعيين النموذج
        _formKey.currentState!.reset();
        _titleController.clear();
        _contentController.clear();
        setState(() {
          _selectedCategory = 'الجميع';
          _selectedEmployeeIds.clear();
          _selectedEmployeeNames.clear();
        });
      } else {
        _showErrorSnackbar(result["message"] ?? 'فشل في إرسال الإشعار');
      }
    } catch (e) {
      _showErrorSnackbar('حدث خطأ أثناء الإرسال: $e');
    } finally {
      setState(() => _isSending = false);
    }
  }

  void _showErrorSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Ar.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  void _showSuccessSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white, size: 20),
            const SizedBox(width: 8),
            Expanded(child: Text(message)),
          ],
        ),
        backgroundColor: Ar.green,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark
            ? AppColors.onSurfaceVariantDark
            : AppColors.onSurfaceVariantLight;
        final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Column(
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          // زر الرجوع
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: isDark
                                    ? Colors.white.withOpacity(0.15)
                                    : Colors.white.withOpacity(0.70),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 14,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                isRTL
                                    ? Icons.arrow_forward_ios_rounded
                                    : Icons.arrow_back_ios_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'إرسال إشعار جديد',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          // زر عرض الإشعارات المرسلة
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => SentNotificationsPage(
                                    uid: widget.uid,
                                    name: widget.name,
                                    role: widget.role,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: isDark
                                    ? Colors.white.withOpacity(0.15)
                                    : Colors.white.withOpacity(0.70),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 14,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.history_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 14),

                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Form(
                          key: _formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              // ملاحظة
                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Ar.info.shade900.withOpacity(0.3)
                                      : Ar.info.shade50,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isDark
                                        ? Ar.info.shade700
                                        : Ar.info.shade200,
                                    width: 1.5,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        color: isDark
                                            ? Ar.info.shade800
                                            : Ar.info.shade100,
                                      ),
                                      child: Icon(
                                        Icons.info_rounded,
                                        color: isDark
                                            ? Ar.info.shade300
                                            : Ar.info.shade800,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            'ملاحظة',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w800,
                                              color: isDark
                                                  ? Ar.info.shade300
                                                  : Ar.info.shade800,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'اختر الفئة ثم اختر الموظفين المحددين أو استخدم خيار "الجميع"',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: isDark
                                                  ? Ar.info.shade200
                                                  : Ar.info.shade600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // اختيار الفئة
                              Text(
                                'الفئة المستهدفة *',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: textColor,
                                ),
                              ),
                              const SizedBox(height: 8),

                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withOpacity(0.15)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: _selectedCategory,
                                    isExpanded: true,
                                    items: _categories.map((category) {
                                      return DropdownMenuItem<String>(
                                        value: category,
                                        child: Text(
                                          _categoryLabels[category] ?? category,
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: textColor,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                    onChanged: (String? newValue) {
                                      if (newValue != null) {
                                        setState(() {
                                          _selectedCategory = newValue;
                                          _selectedEmployeeIds.clear();
                                          _selectedEmployeeNames.clear();
                                        });
                                      }
                                    },
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: textColor,
                                    ),
                                    dropdownColor: isDark
                                        ? const Color(0xFF262624)
                                        : Colors.white,
                                    borderRadius: BorderRadius.circular(16),
                                    icon: Icon(
                                      Icons.arrow_drop_down_rounded,
                                      color: primaryColor,
                                      size: 28,
                                    ),
                                  ),
                                ),
                              ),

                              // اختيار الموظفين (إذا لم تكن الفئة "الجميع")
                              if (_selectedCategory != 'الجميع') ...[
                                Text(
                                  'اختيار الموظفين',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w800,
                                    color: textColor,
                                  ),
                                ),
                                const SizedBox(height: 8),

                                if (_isLoading)
                                  Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(16),
                                      child: CircularProgressIndicator(
                                        color: primaryColor,
                                      ),
                                    ),
                                  )
                                else
                                  _buildEmployeeSelection(
                                    isDark: isDark,
                                    textColor: textColor,
                                    subduedTextColor: subduedTextColor,
                                    primaryColor: primaryColor,
                                  ),
                              ],

                              const SizedBox(height: 16),

                              // العنوان
                              Text(
                                'عنوان الإشعار *',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: textColor,
                                ),
                              ),
                              const SizedBox(height: 8),

                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withOpacity(0.15)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: TextFormField(
                                  controller: _titleController,
                                  decoration: InputDecoration(
                                    hintText: 'أدخل عنوان الإشعار',
                                    hintStyle: TextStyle(color: subduedTextColor),
                                    border: InputBorder.none,
                                  ),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                  maxLength: 100,
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return 'هذا الحقل مطلوب';
                                    }
                                    if (value.trim().length < 3) {
                                      return 'العنوان يجب أن يكون 3 أحرف على الأقل';
                                    }
                                    return null;
                                  },
                                ),
                              ),

                              // المحتوى
                              Text(
                                'محتوى الإشعار *',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w800,
                                  color: textColor,
                                ),
                              ),
                              const SizedBox(height: 8),

                              Container(
                                margin: const EdgeInsets.only(bottom: 16),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withOpacity(0.15)
                                      : Colors.white,
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withOpacity(0.1),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: TextFormField(
                                  controller: _contentController,
                                  maxLines: 6,
                                  minLines: 4,
                                  decoration: InputDecoration(
                                    hintText: 'أدخل محتوى الإشعار هنا...',
                                    hintStyle: TextStyle(color: subduedTextColor),
                                    border: InputBorder.none,
                                  ),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: textColor,
                                  ),
                                  maxLength: 500,
                                  validator: (value) {
                                    if (value == null || value.trim().isEmpty) {
                                      return 'هذا الحقل مطلوب';
                                    }
                                    if (value.trim().length < 10) {
                                      return 'المحتوى يجب أن يكون 10 أحرف على الأقل';
                                    }
                                    return null;
                                  },
                                ),
                              ),

                              // ملاحظة حول الإرسال
                              Container(
                                margin: const EdgeInsets.only(bottom: 24),
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Ar.green.shade900.withOpacity(0.3)
                                      : Ar.green.shade100,
                                  borderRadius: BorderRadius.circular(20),
                                  border: Border.all(
                                    color: isDark
                                        ? Ar.green.shade700
                                        : Ar.green.shade200,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 44,
                                      height: 44,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(12),
                                        color: isDark
                                            ? Ar.green.shade800
                                            : Ar.green.shade50,
                                      ),
                                      child: Icon(
                                        Icons.send_rounded,
                                        color: isDark
                                            ? Ar.green.shade300
                                            : Ar.green.shade800,
                                        size: 22,
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Text(
                                            'معلومات الإرسال',
                                            style: TextStyle(
                                              fontSize: 16,
                                              fontWeight: FontWeight.w800,
                                              color: isDark
                                                  ? Ar.green.shade300
                                                  : Ar.green.shade800,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'سيتم إرسال الإشعار إلى ${_getRecipientCount()} مستخدم',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: isDark
                                                  ? Ar.green.shade200
                                                  : Ar.green.shade700,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),

                              // زر الإرسال
                              Container(
                                margin: const EdgeInsets.only(bottom: 30),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(20),
                                  boxShadow: [
                                    BoxShadow(
                                      color: primaryColor.withOpacity(0.4),
                                      blurRadius: 20,
                                      spreadRadius: 2,
                                    ),
                                  ],
                                ),
                                child: ElevatedButton(
                                  onPressed: _isSending ? null : _sendNotification,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: primaryColor,
                                    foregroundColor: Colors.white,
                                    minimumSize: const Size(double.infinity, 58),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: _isSending
                                      ? Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: Colors.white,
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        'جاري الإرسال...',
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w800,
                                        ),
                                      ),
                                    ],
                                  )
                                      : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.send_rounded, size: 22),
                                      const SizedBox(width: 10),
                                      Text(
                                        'إرسال الإشعار',
                                        style: const TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildEmployeeSelection({
    required bool isDark,
    required Color textColor,
    required Color subduedTextColor,
    required Color primaryColor,
  }) {
    final filteredEmployees = _getFilteredEmployees();

    if (filteredEmployees.isEmpty) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark
              ? Ar.red.shade900.withOpacity(0.3)
              : Ar.red.shade50,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isDark
                ? Ar.red.shade700
                : Ar.red.shade200,
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_rounded,
              color: isDark ? Ar.red.shade300 : Ar.red.shade800,
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'لا يوجد موظفين في هذه الفئة',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: isDark ? Ar.red.shade300 : Ar.red.shade800,
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        // زر تحديد الكل/إلغاء التحديد
        Container(
          margin: const EdgeInsets.only(bottom: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isDark
                ? Ar.info.shade900.withOpacity(0.3)
                : Ar.info.shade50,
          ),
          child: ListTile(
            onTap: _selectAllEmployees,
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: isDark
                    ? Ar.info.shade800
                    : Ar.info.shade100,
              ),
              child: Icon(
                _selectedEmployeeIds.length == filteredEmployees.length
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                color: primaryColor,
                size: 22,
              ),
            ),
            title: Text(
              _selectedEmployeeIds.length == filteredEmployees.length
                  ? 'إلغاء تحديد الكل'
                  : 'تحديد الكل',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: textColor,
              ),
            ),
            trailing: Text(
              '${_selectedEmployeeIds.length}/${filteredEmployees.length}',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: primaryColor,
              ),
            ),
          ),
        ),

        // قائمة الموظفين
        ...filteredEmployees.map((employee) {
          final uid = employee['uid'].toString();
          final name = employee['name'].toString();
          final isSelected = _selectedEmployeeIds.contains(uid);

          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: isSelected
                  ? (isDark
                  ? primaryColor.withOpacity(0.3)
                  : primaryColor.withOpacity(0.1))
                  : (isDark
                  ? Colors.white.withOpacity(0.1)
                  : Ar.grey.shade50),
              border: Border.all(
                color: isSelected
                    ? primaryColor.withOpacity(0.5)
                    : (isDark
                    ? Colors.white.withOpacity(0.2)
                    : Ar.grey.shade300),
              ),
            ),
            child: ListTile(
              onTap: () => _toggleEmployee(uid, name),
              leading: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: isSelected
                      ? primaryColor.withOpacity(0.2)
                      : (isDark
                      ? Colors.white.withOpacity(0.1)
                      : Ar.grey.shade100),
                ),
                child: Icon(
                  isSelected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: isSelected ? primaryColor : subduedTextColor,
                  size: 22,
                ),
              ),
              title: Text(
                name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
              subtitle: Text(
                'UID: $uid',
                style: TextStyle(
                  fontSize: 12,
                  color: subduedTextColor,
                ),
              ),
              trailing: Icon(
                isSelected ? Icons.check_circle_rounded : Icons.person_rounded,
                color: isSelected ? primaryColor : subduedTextColor,
              ),
            ),
          );
        }).toList(),
      ],
    );
  }

  String _getRecipientCount() {
    if (_selectedCategory == 'الجميع') {
      return '${_employees.length}';
    }
    return '${_selectedEmployeeIds.length}';
  }
}