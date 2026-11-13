import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../services/leave_request_api.dart';
import '../services/employee_api.dart';
import '../widgets/app_background.dart';
import '../theme/app_colors.dart';
import '../l10n/app_localizations.dart';
import 'leave_summary.dart';
import '../widgets/glass_dialog.dart';
import '../widgets/glass_ui.dart';

class LeaveRequestPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const LeaveRequestPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<LeaveRequestPage> createState() => _LeaveRequestPageState();
}

class _LeaveRequestPageState extends State<LeaveRequestPage> {
  final ImagePicker _picker = ImagePicker();
  final _formKey = GlobalKey<FormState>();

  DateTime? _fromDate;
  DateTime? _toDate;
  String _leaveType = 'إجازة بدون راتب';
  String _reason = '';
  File? _selectedImage;
  bool _isSubmitting = false;

  List<Map<String, dynamic>> _activeEmployees = [];
  String? _selectedEmployeeId;
  String? _selectedEmployeeName;
  bool _isLoadingEmployees = true;

  final List<String> _leaveTypes = [
    'إجازة بدون راتب',
    'إجازة مرضية',
    'إجازة عادية',
    'إجازة طارئة',
  ];

  final Map<String, IconData> _leaveTypeIcons = {
    'إجازة بدون راتب': Icons.money_off_rounded,
    'إجازة مرضية': Icons.medical_services_rounded,
    'إجازة عادية': Icons.beach_access_rounded,
    'إجازة طارئة': Icons.emergency_rounded,
  };

  final Map<String, Color> _leaveTypeColors = {
    'إجازة بدون راتب': Ar.grey,
    'إجازة مرضية': Ar.red,
    'إجازة عادية': Ar.green,
    'إجازة طارئة': Ar.amber,
  };

  @override
  void initState() {
    super.initState();
    _loadActiveEmployees();
  }

  Future<void> _loadActiveEmployees() async {
    try {
      final result = await EmployeeApi.getActiveEmployees();
      if (result["success"] == true) {
        setState(() {
          _activeEmployees = List<Map<String, dynamic>>.from(result["employees"] ?? []);
          _isLoadingEmployees = false;

          // إذا كانت القائمة غير فارغة، نختار أول موظف افتراضيًا
          if (_activeEmployees.isNotEmpty) {
            _selectedEmployeeId = _activeEmployees[0]["uid"];
            _selectedEmployeeName = _activeEmployees[0]["name"];
          }
        });
      } else {
        _showErrorDialog(result["message"] ?? "فشل في تحميل قائمة الموظفين");
        setState(() {
          _isLoadingEmployees = false;
        });
      }
    } catch (e) {
      _showErrorDialog("حدث خطأ أثناء تحميل الموظفين: $e");
      setState(() {
        _isLoadingEmployees = false;
      });
    }
  }

  String _tr(String key) {
    try {
      return AppLocalizations.of(context, key);
    } catch (e) {
      return key;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark
            ? AppColors.onSurfaceVariantDark
            : AppColors.onSurfaceVariantLight;

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
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.70),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 14,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                isRTL ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'إضافة طلب إجازة',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => LeaveSummaryPage(
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
                                color: isDark ? Colors.white.withOpacity(0.15) : Colors.white.withOpacity(0.70),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.08),
                                    blurRadius: 14,
                                    offset: const Offset(0, 8),
                                  ),
                                ],
                              ),
                              child: Icon(
                                Icons.summarize_rounded,
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
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(16),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: IntrinsicHeight(
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      // زر الانتقال السريع إلى ملخص الإجازات
                                      GestureDetector(
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) => LeaveSummaryPage(
                                                uid: widget.uid,
                                                name: widget.name,
                                                role: widget.role,
                                              ),
                                            ),
                                          );
                                        },
                                        child: Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          decoration: BoxDecoration(
                                            color: isDark ? Ar.info.shade900.withOpacity(0.3) : Ar.info.shade50,
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(
                                              color: isDark ? Ar.info.shade700 : Ar.info.shade200,
                                              width: 1.5,
                                            ),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withOpacity(0.1),
                                                blurRadius: 10,
                                                offset: const Offset(0, 4),
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 44,
                                                height: 44,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(12),
                                                  color: isDark ? Ar.info.shade800 : Ar.info.shade100,
                                                ),
                                                child: Icon(
                                                  Icons.summarize_rounded,
                                                  color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                  size: 24,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      'ملخص الإجازات',
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.w800,
                                                        color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      'عرض جميع طلبات الإجازة والإحصائيات',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: isDark ? Ar.info.shade200 : Ar.info.shade600,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Icon(
                                                isRTL ? Icons.arrow_back_ios_rounded : Icons.arrow_forward_ios_rounded,
                                                color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                size: 18,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),

                                      // زر اختيار الموظف - بنفس شكل تقرير الحضور
                                      _buildEmployeeDropdown(isDark, textColor, subduedTextColor),

                                      const SizedBox(height: 20),

                                      // بيانات طلب الإجازة
                                      Text(
                                        'بيانات طلب الإجازة',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 16),

                                      // نوع الإجازة
                                      _buildLeaveTypeButton(isDark, textColor, subduedTextColor, primaryColor),

                                      const SizedBox(height: 16),

                                      // زر اختيار فترة الإجازة
                                      _buildDateRangeButton(isDark, textColor, subduedTextColor, primaryColor),

                                      const SizedBox(height: 16),

                                      // عرض التواريخ المختارة
                                      if (_fromDate != null || _toDate != null)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade50,
                                            borderRadius: BorderRadius.circular(20),
                                            border: Border.all(
                                              color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300,
                                            ),
                                          ),
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Text(
                                                'فترة الإجازة المحددة',
                                                style: TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800,
                                                  color: textColor,
                                                ),
                                              ),
                                              const SizedBox(height: 12),
                                              if (_fromDate != null)
                                                _buildDateDisplayRow(
                                                  label: 'من التاريخ:',
                                                  date: _fromDate!,
                                                  icon: Icons.event_available_rounded,
                                                  isDark: isDark,
                                                  textColor: textColor,
                                                ),
                                              if (_toDate != null) ...[
                                                const SizedBox(height: 8),
                                                _buildDateDisplayRow(
                                                  label: 'إلى التاريخ:',
                                                  date: _toDate!,
                                                  icon: Icons.event_busy_rounded,
                                                  isDark: isDark,
                                                  textColor: textColor,
                                                ),
                                              ],
                                              if (_fromDate != null && _toDate != null) ...[
                                                const SizedBox(height: 12),
                                                Divider(
                                                  color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade400,
                                                  height: 1,
                                                ),
                                                const SizedBox(height: 12),
                                                Row(
                                                  children: [
                                                    Icon(
                                                      Icons.calculate_rounded,
                                                      color: primaryColor,
                                                      size: 20,
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Text(
                                                      'عدد الأيام: ',
                                                      style: TextStyle(
                                                        fontSize: 14,
                                                        fontWeight: FontWeight.w600,
                                                        color: subduedTextColor,
                                                      ),
                                                    ),
                                                    const Spacer(),
                                                    Text(
                                                      '${_calculateDays()} يوم',
                                                      style: TextStyle(
                                                        fontSize: 18,
                                                        fontWeight: FontWeight.w900,
                                                        color: primaryColor,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ],
                                          ),
                                        ),

                                      const SizedBox(height: 16),

                                      // ملاحظة ذكية
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 16),
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: isDark ? Ar.info.shade900.withOpacity(0.3) : Ar.info.shade100,
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: isDark ? Ar.info.shade700 : Ar.info.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                color: isDark ? Ar.info.shade800 : Ar.info.shade50,
                                              ),
                                              child: Icon(
                                                Icons.info_rounded,
                                                color: isDark ? Ar.info.shade300 : Ar.info,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    'ملاحظة ذكية',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'عند اختيار تاريخ البداية فقط سيتم تعيين تاريخ النهاية لنفس اليوم لطلبات الإجازة ليوم واحد تلقائياً.',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                      color: isDark ? Ar.info.shade200 : Ar.info.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 16),

                                      // سبب الإجازة
                                      Text(
                                        'سبب الإجازة',
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
                                          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
                                          borderRadius: BorderRadius.circular(20),
                                          boxShadow: [
                                            BoxShadow(
                                              color: Colors.black.withOpacity(0.1),
                                              blurRadius: 10,
                                            ),
                                          ],
                                        ),
                                        child: TextFormField(
                                          maxLines: 4,
                                          minLines: 3,
                                          decoration: InputDecoration(
                                            hintText: 'اكتب سبب الإجازة هنا...',
                                            hintStyle: TextStyle(
                                              color: subduedTextColor,
                                              fontSize: 16,
                                            ),
                                            border: InputBorder.none,
                                            contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                          ),
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: textColor,
                                          ),
                                          onChanged: (value) => _reason = value,
                                          validator: (value) {
                                            if (value == null || value.trim().isEmpty) {
                                              return 'هذا الحقل مطلوب';
                                            }
                                            if (value.trim().length < 10) {
                                              return 'يرجى كتابة سبب مفصل (10 أحرف على الأقل)';
                                            }
                                            return null;
                                          },
                                        ),
                                      ),

                                      const SizedBox(height: 8),

                                      // نصيحة
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 16),
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: isDark ? Ar.amber.shade900.withOpacity(0.3) : Ar.amber.shade100,
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: isDark ? Ar.amber.shade700 : Ar.amber.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                color: isDark ? Ar.amber.shade800 : Ar.amber.shade50,
                                              ),
                                              child: Icon(
                                                Icons.lightbulb_rounded,
                                                color: isDark ? Ar.amber.shade300 : Ar.amber,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    'نصيحة',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? Ar.amber.shade300 : Ar.amber.shade800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'قدم سبباً واضحاً ومفصلاً لتسهيل عملية الموافقة على طلبك.',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                      color: isDark ? Ar.amber.shade200 : Ar.amber.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 16),

                                      // المرفق
                                      Text(
                                        'المرفق (اختياري)',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 8),

                                      if (_selectedImage == null)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                          decoration: BoxDecoration(
                                            color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
                                            borderRadius: BorderRadius.circular(20),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withOpacity(0.1),
                                                blurRadius: 10,
                                              ),
                                            ],
                                          ),
                                          child: GestureDetector(
                                            onTap: _pickImage,
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 44,
                                                  height: 44,
                                                  decoration: BoxDecoration(
                                                    borderRadius: BorderRadius.circular(12),
                                                    color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFEDEAE5),
                                                  ),
                                                  child: Icon(
                                                    Icons.add_photo_alternate_rounded,
                                                    color: primaryColor,
                                                    size: 22,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.end,
                                                    children: [
                                                      Text(
                                                        'إضافة صورة',
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight: FontWeight.w800,
                                                          color: textColor,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        'اضغط هنا لإضافة صورة (اختياري)',
                                                        style: TextStyle(
                                                          fontSize: 14,
                                                          fontWeight: FontWeight.w600,
                                                          color: subduedTextColor,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Icon(
                                                  isRTL ? Icons.arrow_back_ios_rounded : Icons.arrow_forward_ios_rounded,
                                                  color: subduedTextColor,
                                                  size: 26,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),

                                      if (_selectedImage != null) ...[
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.all(16),
                                          decoration: BoxDecoration(
                                            color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
                                            borderRadius: BorderRadius.circular(20),
                                            boxShadow: [
                                              BoxShadow(
                                                color: Colors.black.withOpacity(0.1),
                                                blurRadius: 10,
                                              ),
                                            ],
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 60,
                                                height: 60,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(12),
                                                  image: DecorationImage(
                                                    image: FileImage(_selectedImage!),
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      'الصورة المرفقة',
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.w800,
                                                        color: textColor,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      _selectedImage!.path.split('/').last,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: subduedTextColor,
                                                      ),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              IconButton(
                                                icon: Icon(
                                                  Icons.delete_rounded,
                                                  color: isDark ? const Color(0xFFFF7D6E) : const Color(0xFFE5604F),
                                                  size: 24,
                                                ),
                                                onPressed: () {
                                                  setState(() {
                                                    _selectedImage = null;
                                                  });
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        GestureDetector(
                                          onTap: _pickImage,
                                          child: Text(
                                            'تغيير الصورة',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: primaryColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                      ],

                                      // ملاحظة للمدير
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 24),
                                        padding: const EdgeInsets.all(16),
                                        decoration: BoxDecoration(
                                          color: isDark ? Ar.green.shade900.withOpacity(0.3) : Ar.green.shade100,
                                          borderRadius: BorderRadius.circular(20),
                                          border: Border.all(
                                            color: isDark ? Ar.green.shade700 : Ar.green.shade200,
                                          ),
                                        ),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                color: isDark ? Ar.green.shade800 : Ar.green.shade50,
                                              ),
                                              child: Icon(
                                                Icons.admin_panel_settings_rounded,
                                                color: isDark ? Ar.green.shade300 : Ar.green,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    'ملاحظة للمدير',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? Ar.green.shade300 : Ar.green.shade800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'سيتم إضافة الطلب تلقائياً بحالة "مقبؤل" ومراجعة المدير التنفيذي.',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                      color: isDark ? Ar.green.shade200 : Ar.green.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // إرسال الآن
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
                                          onPressed: _isSubmitting ? null : _submitLeaveRequest,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: primaryColor,
                                            foregroundColor: Colors.white,
                                            minimumSize: const Size(double.infinity, 58),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            elevation: 0,
                                          ),
                                          child: _isSubmitting
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
                                                'إرسال طلب الإجازة',
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
                          );
                        },
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

  // زر اختيار الموظف - بنفس شكل تقرير الحضور
  Widget _buildEmployeeDropdown(bool isDark, Color textColor, Color subduedTextColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
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
          value: _selectedEmployeeId,
          isExpanded: true,
          items: _activeEmployees.map((employee) {
            return DropdownMenuItem<String>(
              value: employee['uid'],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    employee['name'] ?? 'غير معروف',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'UID: ${employee['uid']}',
                    style: TextStyle(
                      fontSize: 12,
                      color: subduedTextColor,
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (String? newValue) {
            if (newValue != null) {
              final selectedEmployee = _activeEmployees.firstWhere(
                    (emp) => emp['uid'] == newValue,
                orElse: () => {'uid': '', 'name': 'غير معروف'},
              );

              setState(() {
                _selectedEmployeeId = newValue;
                _selectedEmployeeName = selectedEmployee['name'];
              });
            }
          },
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: textColor,
          ),
          dropdownColor: isDark ? const Color(0xFF262624) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          icon: Icon(
            Icons.arrow_drop_down_rounded,
            color: isDark ? Ar.info.shade300 : Ar.info,
            size: 28,
          ),
          hint: _isLoadingEmployees
              ? const Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 8),
              Text('جاري التحميل...'),
            ],
          )
              : _activeEmployees.isEmpty
              ? const Text('لا يوجد موظفين')
              : null,
          elevation: 8,
          menuMaxHeight: 400,
        ),
      ),
    );
  }

  Widget _buildLeaveTypeButton(bool isDark, Color textColor, Color subduedTextColor, Color primaryColor) {
    final icon = _leaveTypeIcons[_leaveType] ?? Icons.work_off_rounded;
    final iconColor = _leaveTypeColors[_leaveType] ?? primaryColor;

    return GestureDetector(
      onTap: () => _openLeaveTypeSheet(isDark),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? iconColor.withOpacity(0.2) : iconColor.withOpacity(0.1),
              ),
              child: Icon(
                icon,
                color: iconColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'نوع الإجازة *',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: subduedTextColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _leaveType,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: primaryColor,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateRangeButton(bool isDark, Color textColor, Color subduedTextColor, Color primaryColor) {
    return GestureDetector(
      onTap: () => _openDateRangeSheet(isDark),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.15) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
            ),
          ],
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFEDEAE5),
              ),
              child: Icon(
                Icons.calendar_month_rounded,
                color: primaryColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'فترة الإجازة *',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: subduedTextColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _fromDate != null && _toDate != null
                        ? '${DateFormat('yyyy-MM-dd').format(_fromDate!)} إلى ${DateFormat('yyyy-MM-dd').format(_toDate!)}'
                        : (_fromDate != null
                        ? '${DateFormat('yyyy-MM-dd').format(_fromDate!)} (يوم واحد)'
                        : 'انقر لاختيار فترة الإجازة'),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: _fromDate != null ? textColor : subduedTextColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: primaryColor,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDateDisplayRow({
    required String label,
    required DateTime date,
    required IconData icon,
    required bool isDark,
    required Color textColor,
  }) {
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade100,
          ),
          child: Icon(
            icon,
            color: textColor,
            size: 18,
          ),
        ),
        const SizedBox(width: 12),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: textColor.withOpacity(0.7),
          ),
        ),
        const Spacer(),
        Text(
          DateFormat('yyyy-MM-dd').format(date),
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w800,
            color: textColor,
          ),
        ),
      ],
    );
  }

  void _openLeaveTypeSheet(bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        final appController = Provider.of<AppController>(context, listen: false);
        final isRTL = appController.isRTL;

        return Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Container(
            margin: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                color: isDark ? const Color(0xFF262624) : Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(
                          Icons.work_off_rounded,
                          color: isDark ? AppColors.primaryLight : AppColors.primary,
                          size: 28,
                        ),
                        const Spacer(),
                        Text(
                          'اختر نوع الإجازة',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(sheetContext),
                          child: Icon(
                            Icons.close_rounded,
                            color: isDark ? Colors.white70 : Ar.grey.shade600,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    ..._leaveTypes.map((type) {
                      final icon = _leaveTypeIcons[type] ?? Icons.work_off_rounded;
                      final iconColor = _leaveTypeColors[type] ?? Ar.grey;
                      final isSelected = type == _leaveType;

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _leaveType = type;
                          });
                          Navigator.pop(sheetContext);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (isDark ? iconColor.withOpacity(0.3) : iconColor.withOpacity(0.15))
                                : (isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade50),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? iconColor.withOpacity(0.5)
                                  : (isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: isDark ? iconColor.withOpacity(0.2) : iconColor.withOpacity(0.1),
                                ),
                                child: Icon(
                                  icon,
                                  color: iconColor,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  type,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                              ),
                              if (isSelected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: iconColor,
                                  size: 24,
                                ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  int _calculateDays() {
    if (_fromDate == null || _toDate == null) return 0;
    final difference = _toDate!.difference(_fromDate!);
    return difference.inDays + 1;
  }

  void _openDateRangeSheet(bool isDark) {
    DateTime tmpFrom = _fromDate ?? DateTime.now();
    DateTime tmpTo = _toDate ?? DateTime.now();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return StatefulBuilder(
          builder: (ctx, setS) {
            final appController = Provider.of<AppController>(context, listen: false);
            final isRTL = appController.isRTL;

            return Directionality(
              textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
              child: Container(
                margin: const EdgeInsets.all(16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(26),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                    color: isDark ? const Color(0xFF262624) : Colors.white,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Icon(
                              Icons.calendar_month_rounded,
                              color: isDark ? AppColors.primaryLight : AppColors.primary,
                              size: 28,
                            ),
                            const Spacer(),
                            Text(
                              'اختر فترة الإجازة',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                color: isDark ? Colors.white : Colors.black87,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () => Navigator.pop(sheetContext),
                              child: Icon(
                                Icons.close_rounded,
                                color: isDark ? Colors.white70 : Ar.grey.shade600,
                                size: 28,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        _buildDateFieldInSheet(
                          label: 'من التاريخ',
                          date: tmpFrom,
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: sheetContext,
                              initialDate: tmpFrom,
                              firstDate: DateTime(2023, 1, 1),
                              lastDate: DateTime(2026, 12, 31),
                              locale: isRTL ? const Locale('ar') : const Locale('en'),
                              builder: (BuildContext context, Widget? child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: ColorScheme.light(
                                      primary: AppColors.primary,
                                      onPrimary: Colors.white,
                                      surface: Colors.white,
                                      onSurface: Colors.black,
                                    ),
                                    dialogBackgroundColor: Colors.white,
                                  ),
                                  child: child!,
                                );
                              },
                            );
                            if (picked != null) {
                              setS(() {
                                tmpFrom = picked;
                                if (tmpTo.isBefore(picked)) {
                                  tmpTo = picked;
                                }
                              });
                            }
                          },
                          isDark: isDark,
                        ),
                        const SizedBox(height: 12),

                        _buildDateFieldInSheet(
                          label: 'إلى التاريخ',
                          date: tmpTo,
                          onTap: () async {
                            final picked = await showDatePicker(
                              context: sheetContext,
                              initialDate: tmpTo,
                              firstDate: tmpFrom,
                              lastDate: DateTime(2026, 12, 31),
                              locale: isRTL ? const Locale('ar') : const Locale('en'),
                              builder: (BuildContext context, Widget? child) {
                                return Theme(
                                  data: Theme.of(context).copyWith(
                                    colorScheme: ColorScheme.light(
                                      primary: AppColors.primary,
                                      onPrimary: Colors.white,
                                      surface: Colors.white,
                                      onSurface: Colors.black,
                                    ),
                                    dialogBackgroundColor: Colors.white,
                                  ),
                                  child: child!,
                                );
                              },
                            );
                            if (picked != null) {
                              setS(() => tmpTo = picked);
                            }
                          },
                          isDark: isDark,
                        ),
                        const SizedBox(height: 18),

                        Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isDark ? Ar.info.shade900.withOpacity(0.3) : Ar.info.shade50,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isDark ? Ar.info.shade700 : Ar.info.shade200,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.info_rounded,
                                color: isDark ? Ar.info.shade300 : Ar.info,
                                size: 22,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    Text(
                                      'مدة الإجازة',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w800,
                                        color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                      ),
                                    ),
                                    Text(
                                      '${_calculateDaysForSheet(tmpFrom, tmpTo)} يوم',
                                      style: TextStyle(
                                        fontSize: 18,
                                        fontWeight: FontWeight.w900,
                                        color: isDark ? Colors.white : Ar.info.shade900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 18),

                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () => Navigator.pop(sheetContext),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade200,
                                  foregroundColor: isDark ? Colors.white : Colors.black87,
                                  minimumSize: const Size(double.infinity, 50),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  'إلغاء',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    _fromDate = tmpFrom;
                                    _toDate = tmpTo;
                                  });
                                  Navigator.pop(sheetContext);
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDark ? AppColors.primaryLight : AppColors.primary,
                                  foregroundColor: Colors.white,
                                  minimumSize: const Size(double.infinity, 50),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(16),
                                  ),
                                  elevation: 0,
                                ),
                                child: Text(
                                  'تأكيد الفترة',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildDateFieldInSheet({
    required String label,
    required DateTime date,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade50,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFEDEAE5),
              ),
              child: Icon(
                Icons.calendar_today_rounded,
                color: isDark ? AppColors.primaryLight : AppColors.primary,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isDark ? Colors.white70 : Ar.grey.shade700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    DateFormat('yyyy-MM-dd').format(date),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: isDark ? Colors.white : Colors.black87,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: isDark ? AppColors.primaryLight : AppColors.primary,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }

  int _calculateDaysForSheet(DateTime from, DateTime to) {
    final difference = to.difference(from);
    return difference.inDays + 1;
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1200,
    );

    if (image != null) {
      setState(() {
        _selectedImage = File(image.path);
      });
    }
  }

  void _showInfoDialog() {
    final appController = Provider.of<AppController>(context, listen: false);
    final isRTL = appController.isRTL;

    showDialog(
      context: context,
      builder: (context) {
        return Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: GlassAlertDialog(
            title: const Text('معلومات عن طلب الإجازة'),
            content: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('• تأكد من صحة المعلومات قبل الإرسال'),
                SizedBox(height: 8),
                Text('• ستصلك رسالة تأكيد على البريد الإلكتروني'),
                SizedBox(height: 8),
                Text('• يمكنك متابعة حالة الطلب من قسم الإجازات'),
                SizedBox(height: 8),
                Text('• مدة المعالجة: 1-3 أيام عمل'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('حسناً'),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _submitLeaveRequest() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_fromDate == null || _toDate == null) {
      _showErrorDialog('يرجى اختيار فترة الإجازة');
      return;
    }

    if (_fromDate!.isAfter(_toDate!)) {
      _showErrorDialog('تاريخ البداية يجب أن يكون قبل تاريخ النهاية');
      return;
    }

    if (_selectedEmployeeId == null) {
      _showErrorDialog('يرجى اختيار الموظف');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      String? imageBase64;
      if (_selectedImage != null) {
        final bytes = await _selectedImage!.readAsBytes();
        final base64Raw = base64Encode(bytes);
        imageBase64 = "data:image/jpeg;base64,$base64Raw";
      }

      final res = await LeaveRequestApi.submitLeaveRequestByManager(
        uid: widget.uid,
        employeeId: _selectedEmployeeId!,
        leaveType: _leaveType,
        fromDate: DateFormat('yyyy-MM-dd').format(_fromDate!),
        toDate: DateFormat('yyyy-MM-dd').format(_toDate!),
        reason: _reason,
        image: imageBase64,
      );

      if (!mounted) return;

      if (res["success"] == true) {
        _showSuccessDialog(res["message"] ?? 'تم إضافة طلب الإجازة بنجاح للموظف: $_selectedEmployeeName');

        _formKey.currentState!.reset();
        setState(() {
          _fromDate = null;
          _toDate = null;
          _leaveType = 'إجازة بدون راتب';
          _reason = '';
          _selectedImage = null;
          _selectedEmployeeId = null;
          _selectedEmployeeName = null;
        });

        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        });
      } else {
        _showErrorDialog(res["message"] ?? 'حدث خطأ أثناء إضافة الطلب');
      }
    } catch (e) {
      _showErrorDialog('حدث خطأ أثناء إضافة الطلب: $e');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showErrorDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE5604F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  void _showSuccessDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2FA65A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}