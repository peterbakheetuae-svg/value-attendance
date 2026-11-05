import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../services/employees_api.dart';
import '../../services/api_service.dart';
import '../../widgets/employee_files.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';

class AddEmployeePage extends StatefulWidget {
  final String currentUserId;
  final String currentUserName;
  final String currentUserRole;
  final Function? onEmployeeAdded;

  const AddEmployeePage({
    super.key,
    required this.currentUserId,
    required this.currentUserName,
    required this.currentUserRole,
    this.onEmployeeAdded,
  });

  @override
  State<AddEmployeePage> createState() => _AddEmployeePageState();
}

class _AddEmployeePageState extends State<AddEmployeePage> {
  bool _isLoading = false;
  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();

  // تحكمات النماذج
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _confirmPasswordController = TextEditingController();
  final TextEditingController _dailyRateController = TextEditingController();
  final TextEditingController _joinDateController = TextEditingController();
  final TextEditingController _startSalaryController = TextEditingController();
  final TextEditingController _workHoursController = TextEditingController();

  // متغيرات القوائم المنسدلة
  String? _selectedRole;
  // job positions come from the server (new positions appear here automatically)
  List<Map<String, dynamic>> _positions = [];
  String? _selectedPosition;
  // required documents (uploaded with the new employee)
  final Map<String, PickedDoc?> _docs = {for (final k in docTitles.keys) k: null};
  String? _selectedAccounting;
  String? _selectedManagedBy;
  String? _selectedGeneralManager;
  bool _noAttendance = false;
  TimeOfDay? _workStart;
  TimeOfDay? _workEnd;
  String? _selectedLeaveDay;
  String? _selectedAbsenceMultiplier;
  String? _selectedOvertimeMultiplier;
  String? _selectedStatus;
  bool _isActive = true;

  // قوائم الخيارات
  final List<String> _accountingTypes = ['شهرى'];
  final List<String> _leaveDays = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
  final List<String> _workHoursList = ['10 ساعات', '9 ساعات', '8 ساعات', '7 ساعات', '6 ساعات'];
  final List<String> _multipliers = ['1', '1.25', '1.5', '2'];
  final List<String> _statuses = ['على رأس العمل', 'تم التصفيه', 'مغادر', 'إجازة'];

  // يتبع لـ: مدير مبيعات / المدير / المالك — المدير العام: المدير / المالك
  List<Map<String, dynamic>> _ownersList = [];
  List<Map<String, dynamic>> _gmList = [];
  List<String> _existingUids = [];

  @override
  void initState() {
    super.initState();
    _fetchOwners();
    _initializeDefaultValues();
    _loadPositions();
  }

  Future<void> _loadPositions() async {
    final r = await ApiService.post({'action': 'get_positions'});
    if (!mounted || r['success'] != true) return;
    setState(() {
      _positions = ((r['positions'] as List?) ?? const []).whereType<Map>().map((m) => m.cast<String, dynamic>())
          .where((p) => p['key'] != 'owner').toList();
      _selectedPosition ??= _positions.where((p) => p['key'] == 'sales_employee').map((p) => '${p['name_ar']}').firstOrNull ?? (_positions.isEmpty ? null : '${_positions.first['name_ar']}');
    });
  }

  String? _positionKeyOf(String? name) {
    for (final p in _positions) {
      if (p['name_ar'] == name) return p['key']?.toString();
    }
    return null;
  }

  void _initializeDefaultValues() {
    // تعيين القيم الافتراضية
    _selectedRole = 'مستشار عقاري';
    _selectedAccounting = 'شهرى';
    _selectedLeaveDay = 'الجمعة';
    _selectedAbsenceMultiplier = '1';
    _selectedOvertimeMultiplier = '1.25';
    _selectedStatus = 'على رأس العمل';
    _selectedManagedBy = null;
  }

  Future<void> _fetchOwners() async {
    try {
      final response = await EmployeesApi.getAllEmployees();
      if (response["success"] == true) {
        List<dynamic> employees = response["employees"] ?? [];
        List<Map<String, dynamic>> owners = [];
        List<Map<String, dynamic>> gms = [];
        List<String> existingUids = [];

        for (var emp in employees) {
          final uid = emp['uid']?.toString();
          if (uid != null) {
            existingUids.add(uid);
          }

          final rk = emp['roleKey']?.toString() ?? '';
          final active = emp['active'] != false;
          if (active && ['sales_manager', 'manager', 'owner'].contains(rk)) {
            owners.add({'uid': uid, 'id': emp['id']?.toString(), 'name': emp['name']?.toString()});
          }
          if (active && ['manager', 'owner'].contains(rk)) {
            gms.add({'uid': uid, 'id': emp['id']?.toString(), 'name': emp['name']?.toString()});
          }
        }
        setState(() {
          _ownersList = owners;
          _gmList = gms;
          _existingUids = existingUids;
        });
      } else {
        print('Failed to fetch owners: ${response["message"]}');
        setState(() {
          _ownersList = [];
          _existingUids = [];
        });
      }
    } catch (e) {
      print('Error fetching owners: $e');
      setState(() {
        _ownersList = [];
        _existingUids = [];
      });
    }
  }

  static int _minutes(TimeOfDay t) => t.hour * 60 + t.minute;
  static String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  static String? _idOf(List<Map<String, dynamic>> list, String? name) {
    if (name == null) return null;
    for (final m in list) {
      if (m['name'] == name) return m['id']?.toString();
    }
    return null;
  }

  Future<void> _pickTime(bool start) async {
    final t = await showTimePicker(
      context: context,
      initialTime: (start ? _workStart : _workEnd) ?? (start ? const TimeOfDay(hour: 10, minute: 0) : const TimeOfDay(hour: 18, minute: 0)),
    );
    if (t != null) setState(() => start ? _workStart = t : _workEnd = t);
  }

  Widget _timeTile(String label, TimeOfDay? v, bool start, bool isDark) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          leading: Icon(start ? Icons.login_rounded : Icons.logout_rounded, color: isDark ? Colors.white70 : Colors.grey[600]),
          title: Text(label, style: TextStyle(fontSize: 14, color: isDark ? Colors.white70 : Colors.grey[700])),
          trailing: Text(v == null ? 'دوام الشركة' : _hhmm(v), style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black)),
          onTap: () => _pickTime(start),
        ),
      );

  // دالة لتوليد UID فريد مكون من 4 أرقام
  String _generateUniqueUid() {
    final random = Random();
    String uid;

    do {
      // توليد رقم عشوائي من 1000 إلى 9999 (4 أرقام)
      uid = (1000 + random.nextInt(9000)).toString();
    } while (_existingUids.contains(uid));

    return uid;
  }

  Future<void> _pickImage() async {
    try {
      final pickedFile = await _picker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 80,
      );

      if (pickedFile != null) {
        setState(() {
          _selectedImage = File(pickedFile.path);
        });
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في اختيار الصورة: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _selectJoinDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        _joinDateController.text = "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}";
      });
    }
  }

  // التحقق من صحة البيانات
  String? _validateForm() {
    if (_nameController.text.trim().isEmpty) {
      return 'الاسم مطلوب';
    }
    if (_phoneController.text.trim().isEmpty) {
      return 'رقم الهاتف مطلوب';
    }
    if (_passwordController.text.trim().isEmpty) {
      return 'كلمة المرور مطلوبة';
    }
    if (_passwordController.text.trim().length < 4) {
      return 'كلمة المرور يجب أن تكون 4 أحرف على الأقل';
    }
    if (_passwordController.text.trim() != _confirmPasswordController.text.trim()) {
      return 'كلمات المرور غير متطابقة';
    }
    if (_selectedPosition == null || _positionKeyOf(_selectedPosition) == null) {
      return 'الرجاء اختيار الوظيفة';
    }
    if (_selectedAccounting == null) {
      return 'الرجاء اختيار نوع المحاسبة';
    }
    if (!_noAttendance && (_workStart == null) != (_workEnd == null)) {
      return 'اختار ساعة بداية العمل وساعة نهايته';
    }
    if (!_noAttendance && _workStart != null && _workEnd != null && _minutes(_workEnd!) <= _minutes(_workStart!)) {
      return 'ساعة نهاية العمل لازم تكون بعد ساعة البداية';
    }
    if (_selectedAccounting == 'شهرى' && _startSalaryController.text.trim().isEmpty) {
      return 'راتب البداية مطلوب للمحاسبة الشهرية';
    }
    return null;
  }

  Future<void> _addEmployee() async {
    final validationError = _validateForm();
    if (validationError != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(validationError),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      setState(() {
        _isLoading = true;
      });

      // توليد UID فريد
      final newUid = _generateUniqueUid();

      // البحث عن UID الخاص بالمدير
      String? managedByUid;
      if (_selectedManagedBy != null) {
        for (var owner in _ownersList) {
          if (owner['name'] == _selectedManagedBy) {
            managedByUid = owner['uid'];
            break;
          }
        }
      }

      // optional documents: upload the ones picked; the server attaches them to the employee atomically
      final docIds = <String, String>{};
      for (final e in _docs.entries.where((e) => e.value != null)) {
        final r = await ApiService.post({'action': 'stage_document', 'kind': e.key, 'fileName': e.value!.fileName, 'mime': e.value!.mime, 'data': e.value!.base64});
        if (r['success'] != true) {
          if (mounted) {
            setState(() => _isLoading = false);
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${docTitles[e.key]}: ${r['message'] ?? ''}'), backgroundColor: Colors.red));
          }
          return;
        }
        docIds[e.key] = '${r['id']}';
      }

      final newEmployeeData = {
        'uid': newUid, // إضافة UID المولد
        'documents': {'acknowledgment': docIds['acknowledgment'], 'jobDescription': docIds['job_description'], 'nationalId': docIds['national_id']},
        'name': _nameController.text.trim(),
        'phone': _phoneController.text.trim(),
        'email': _emailController.text.trim().isEmpty ? '' : _emailController.text.trim(),
        'password': _passwordController.text.trim(),
        'role': _selectedRole,
        'position': _positionKeyOf(_selectedPosition) ?? '',
        'dailyRate': _dailyRateController.text.trim().isEmpty ? "0" : _dailyRateController.text.trim(),
        'salary': "0", // قيمة افتراضية للراتب الشهري
        'joinDate': _joinDateController.text.trim().isEmpty ? '' : _joinDateController.text.trim(),
        'accounting': _selectedAccounting,
        'managedBy': _selectedManagedBy,
        'managedByUid': managedByUid ?? '',
        'salesManagerId': _idOf(_ownersList, _selectedManagedBy) ?? '',
        'generalManagerId': _idOf(_gmList, _selectedGeneralManager) ?? '',
        if (ApiService.can('employee.attendance_exempt')) 'attendanceExempt': _noAttendance,
        'workStart': _noAttendance || _workStart == null ? '' : _hhmm(_workStart!),
        'workEnd': _noAttendance || _workEnd == null ? '' : _hhmm(_workEnd!),
        'foremanId': widget.currentUserId,
        'startSalary': _startSalaryController.text.trim().isEmpty ? "0" : _startSalaryController.text.trim(),
        'increase': "0.00", // قيمة افتراضية للزيادة
        'leaveDay': _selectedLeaveDay ?? '',
        'workHours': _selectedAccounting == 'شهرى' ? _workHoursController.text.trim() : '',
        'absenceMultiplier': _selectedAbsenceMultiplier ?? '1',
        'overtimeMultiplier': _selectedOvertimeMultiplier ?? '1.25',
        'level': '0%',
        'status': _selectedStatus ?? 'على رأس العمل',
        'active': _isActive ? '1' : '0',
      };

      print('📤 إرسال بيانات الموظف الجديد: $newEmployeeData');

      final response = await EmployeesApi.addEmployee(
        data: newEmployeeData,
      );

      if (response["success"] == true && mounted) {
        if (_selectedImage != null) {
          final bytes = await _selectedImage!.readAsBytes();
          final base64Image = String.fromCharCodes(bytes);

          await EmployeesApi.updateEmployeePhoto(
            uid: newUid,
            imageBase64: base64Image,
          );
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم إضافة الموظف بنجاح - الرقم التعريفي: $newUid'),
            backgroundColor: Colors.green,
          ),
        );

        if (widget.onEmployeeAdded != null) {
          widget.onEmployeeAdded!();
        }

        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response["message"] ?? 'فشل في إضافة الموظف'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في الإضافة: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
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
                              'إضافة موظف جديد',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(
                              Icons.close,
                              color: isDark ? Colors.white70 : Colors.black54,
                            ),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                    ),

                    // المحتوى الرئيسي
                    Expanded(
                      child: _isLoading
                          ? Center(
                        child: CircularProgressIndicator(
                          color: AppColors.primary,
                        ),
                      )
                          : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // صورة الموظف
                            Center(
                              child: GestureDetector(
                                onTap: _pickImage,
                                child: Stack(
                                  children: [
                                    Container(
                                      width: 120,
                                      height: 120,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        color: isDark
                                            ? Colors.white.withOpacity(0.2)
                                            : Colors.grey[200],
                                        border: Border.all(
                                          color: _isActive
                                              ? (isDark ? Colors.green : Colors.green)
                                              : (isDark ? Colors.red : Colors.red),
                                          width: 3,
                                        ),
                                      ),
                                      child: ClipOval(
                                        child: _selectedImage != null
                                            ? Image.file(
                                          _selectedImage!,
                                          fit: BoxFit.cover,
                                        )
                                            : Center(
                                          child: Icon(
                                            Icons.person_add,
                                            size: 40,
                                            color: isDark ? Colors.white70 : Colors.grey[700],
                                          ),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      bottom: 0,
                                      right: 0,
                                      child: Container(
                                        width: 40,
                                        height: 40,
                                        decoration: BoxDecoration(
                                          color: AppColors.primary,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: isDark ? Colors.black : Colors.white,
                                            width: 3,
                                          ),
                                        ),
                                        child: const Icon(
                                          Icons.camera_alt,
                                          size: 20,
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            const SizedBox(height: 24),

                            // معلومات الموظف الأساسية
                            Text(
                              'معلومات الموظف',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 16),

                            _buildInfoField(
                              label: 'الاسم *',
                              value: _nameController,
                              icon: Icons.person,
                              isEditable: true,
                              isDark: isDark,
                            ),
                            _buildInfoField(
                              label: 'رقم الهاتف *',
                              value: _phoneController,
                              icon: Icons.phone,
                              isEditable: true,
                              keyboardType: TextInputType.phone,
                              isDark: isDark,
                            ),
                            _buildInfoField(
                              label: 'البريد الإلكتروني',
                              value: _emailController,
                              icon: Icons.email,
                              isEditable: true,
                              keyboardType: TextInputType.emailAddress,
                              isDark: isDark,
                            ),
                            _buildInfoField(
                              label: 'كلمة المرور *',
                              value: _passwordController,
                              icon: Icons.lock,
                              isEditable: true,
                              isPassword: true,
                              isDark: isDark,
                            ),
                            _buildInfoField(
                              label: 'تأكيد كلمة المرور *',
                              value: _confirmPasswordController,
                              icon: Icons.lock_outline,
                              isEditable: true,
                              isPassword: true,
                              isDark: isDark,
                            ),
                            _buildDropdownField(
                              label: 'الوظيفة *',
                              value: _positions.any((p) => p['name_ar'] == _selectedPosition) ? _selectedPosition : null,
                              items: _positions.map((p) => '${p['name_ar']}').toList(),
                              icon: Icons.work,
                              isEditable: true,
                              onChanged: (value) {
                                setState(() {
                                  _selectedPosition = value;
                                });
                              },
                              isDark: isDark,
                            ),

                            const SizedBox(height: 24),

                            // المعلومات الإدارية
                            Text(
                              'المعلومات الإدارية',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 16),

                            _buildDropdownField(
                              label: 'المحاسبه *',
                              value: _selectedAccounting,
                              items: _accountingTypes,
                              icon: Icons.account_balance,
                              isEditable: true,
                              onChanged: (value) {
                                setState(() {
                                  _selectedAccounting = value;
                                });
                              },
                              isDark: isDark,
                            ),

                            _buildDropdownField(
                              label: 'المدير المباشر',
                              value: _selectedManagedBy,
                              items: _ownersList.map<String>((owner) => owner['name']?.toString() ?? '').toList(),
                              icon: Icons.supervisor_account,
                              isEditable: true,
                              onChanged: (value) {
                                setState(() {
                                  _selectedManagedBy = value;
                                });
                              },
                              isDark: isDark,
                            ),
                            _buildDropdownField(
                              label: 'المدير العام',
                              value: _selectedGeneralManager,
                              items: _gmList.map<String>((m) => m['name']?.toString() ?? '').toList(),
                              icon: Icons.account_tree_rounded,
                              isEditable: true,
                              onChanged: (value) => setState(() => _selectedGeneralManager = value),
                              isDark: isDark,
                            ),

                            const SizedBox(height: 24),

                            // المعلومات المالية
                            Text(
                              'المعلومات المالية',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 16),

                            if (_selectedAccounting == 'يومى')
                              _buildInfoField(
                                label: 'الأجر اليومي *',
                                value: _dailyRateController,
                                icon: Icons.attach_money,
                                isEditable: true,
                                keyboardType: TextInputType.number,
                                isDark: isDark,
                              ),
                            if (_selectedAccounting == 'شهرى')
                              _buildInfoField(
                                label: 'راتب البداية *',
                                value: _startSalaryController,
                                icon: Icons.money,
                                isEditable: true,
                                keyboardType: TextInputType.number,
                                isDark: isDark,
                              ),

                            const SizedBox(height: 24),

                            // معلومات العمل
                            Text(
                              'معلومات العمل',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 16),

                            _buildJoinDateField(isDark),
                            if (_selectedAccounting == 'شهرى') ...[
                              _buildDropdownField(
                                label: 'يوم الإجازه',
                                value: _selectedLeaveDay,
                                items: _leaveDays,
                                icon: Icons.beach_access,
                                isEditable: true,
                                onChanged: (value) {
                                  setState(() {
                                    _selectedLeaveDay = value;
                                  });
                                },
                                isDark: isDark,
                              ),
                            ],
                            if (ApiService.can('employee.attendance_exempt'))
                              Container(
                                margin: const EdgeInsets.only(bottom: 12),
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: SwitchListTile(
                                  value: _noAttendance,
                                  onChanged: (v) => setState(() => _noAttendance = v),
                                  title: Text('ليس لديه حضور وانصراف', style: TextStyle(fontSize: 16, color: isDark ? Colors.white : Colors.black)),
                                  subtitle: const Text('مش هيظهر له زرار البصمة ومش هيتحسب غياب أو تأخير'),
                                  secondary: Icon(Icons.fingerprint_rounded, color: _noAttendance ? Colors.orange : Colors.green),
                                ),
                              ),
                            if (!_noAttendance) ...[
                              _timeTile('ساعة بداية العمل', _workStart, true, isDark),
                              _timeTile('ساعة نهاية العمل', _workEnd, false, isDark),
                            ],
                            _buildDropdownField(
                              label: 'مضروب الغياب',
                              value: _selectedAbsenceMultiplier,
                              items: _multipliers,
                              icon: Icons.calculate,
                              isEditable: true,
                              onChanged: (value) {
                                setState(() {
                                  _selectedAbsenceMultiplier = value;
                                });
                              },
                              isDark: isDark,
                            ),

                            const SizedBox(height: 24),

                            // معلومات إضافية
                            Text(
                              'معلومات إضافية',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                            const SizedBox(height: 16),

                            _buildDropdownField(
                              label: 'الوضع',
                              value: _selectedStatus,
                              items: _statuses,
                              icon: Icons.work,
                              isEditable: true,
                              onChanged: (value) {
                                setState(() {
                                  _selectedStatus = value;
                                });
                              },
                              isDark: isDark,
                            ),

                            // حالة تسجيل الدخول
                            Container(
                              padding: const EdgeInsets.all(16),
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        _isActive ? Icons.check_circle : Icons.remove_circle,
                                        color: _isActive
                                            ? (isDark ? Colors.green[300] : Colors.green)
                                            : (isDark ? Colors.red[300] : Colors.red),
                                      ),
                                      const SizedBox(width: 12),
                                      Text(
                                        'حالة تسجيل الدخول',
                                        style: TextStyle(
                                          fontSize: 16,
                                          color: isDark ? Colors.white : Colors.black,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Switch(
                                    value: _isActive,
                                    onChanged: (value) {
                                      setState(() {
                                        _isActive = value;
                                      });
                                    },
                                    activeColor: Colors.green,
                                  ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 24),

                            // المستندات المطلوبة
                            Text(
                              'المستندات (اختياري)',
                              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: isDark ? Colors.white : Colors.black),
                            ),
                            const SizedBox(height: 12),
                            GlassCard(
                              child: Column(children: [
                                for (final k in docTitles.keys)
                                  ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading: Icon(_docs[k] == null ? Icons.upload_file_rounded : Icons.check_circle_rounded,
                                        color: _docs[k] == null ? Colors.orange : Colors.green),
                                    title: Text(docTitles[k]!),
                                    subtitle: Text(_docs[k]?.fileName ?? (k == 'national_id' ? 'صورة JPG / PNG' : 'ملف PDF'), maxLines: 1, overflow: TextOverflow.ellipsis),
                                    trailing: TextButton(
                                      onPressed: () async {
                                        final f = await pickDocument(context, k);
                                        if (f != null) setState(() => _docs[k] = f);
                                      },
                                      child: Text(_docs[k] == null ? 'اختيار' : 'تغيير'),
                                    ),
                                  ),
                              ]),
                            ),

                            const SizedBox(height: 32),

                            // أزرار التحكم
                            Column(
                              children: [
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton(
                                    onPressed: _addEmployee,
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: AppColors.primary,
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                    ),
                                    child: const Text(
                                      'إضافة الموظف',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                SizedBox(
                                  width: double.infinity,
                                  child: OutlinedButton(
                                    onPressed: () {
                                      Navigator.pop(context);
                                    },
                                    style: OutlinedButton.styleFrom(
                                      padding: const EdgeInsets.symmetric(vertical: 16),
                                      shape: RoundedRectangleBorder(
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      side: BorderSide(
                                        color: isDark ? Colors.white70 : Colors.grey,
                                      ),
                                    ),
                                    child: Text(
                                      'إلغاء',
                                      style: TextStyle(
                                        fontSize: 16,
                                        color: isDark ? Colors.white70 : Colors.grey[700],
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),

                            // ملاحظات
                            Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isDark ? Colors.blue.withOpacity(0.1) : Colors.blue.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isDark ? Colors.blue.withOpacity(0.3) : Colors.blue.withOpacity(0.2),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.info,
                                    color: isDark ? Colors.blue[300] : Colors.blue[700],
                                    size: 20,
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'الحقول التي تحمل علامة (*) إلزامية\nسيتم توليد رقم تعريف الموظف (UID) تلقائياً',
                                      style: TextStyle(
                                        fontSize: 14,
                                        color: isDark ? Colors.blue[300] : Colors.blue[700],
                                      ),
                                    ),
                                  ),
                                ],
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
    );
  }

  Widget _buildInfoField({
    required String label,
    required TextEditingController value,
    required IconData icon,
    required bool isEditable,
    required bool isDark,
    bool isPassword = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white70 : Colors.grey[700],
            ),
          ),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: isDark ? Colors.white70 : Colors.grey[600],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: value,
                      keyboardType: keyboardType,
                      obscureText: isPassword,
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                      decoration: const InputDecoration(
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoinDateField(bool isDark) {
    return Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'تاريخ الانضمام',
              style: TextStyle(
                fontSize: 14,
                color: isDark ? Colors.white70 : Colors.grey[700],
              ),
            ),
            const SizedBox(height: 4),
            Container(
              decoration: BoxDecoration(
                color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Icon(
                      Icons.calendar_today,
                      color: isDark ? Colors.white70 : Colors.grey[600],
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: _selectJoinDate,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            _joinDateController.text.isNotEmpty ? _joinDateController.text : 'اختر تاريخ الانضمام',
                            style: TextStyle(
                              fontSize: 16,
                              color: isDark ? Colors.white : Colors.black,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        )
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String? value,
    required List<String> items,
    required IconData icon,
    required bool isEditable,
    required Function(String?) onChanged,
    required bool isDark,
  }) {
    // إزالة القيم الفارغة والتكرارات من القائمة
    List<String> filteredItems = items.where((item) => item.isNotEmpty).toSet().toList();

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              color: isDark ? Colors.white70 : Colors.grey[700],
            ),
          ),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  Icon(
                    icon,
                    color: isDark ? Colors.white70 : Colors.grey[600],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButton<String>(
                      value: filteredItems.contains(value) ? value : null,
                      items: filteredItems.map((item) {
                        return DropdownMenuItem<String>(
                          value: item,
                          child: Text(item),
                        );
                      }).toList(),
                      onChanged: onChanged,
                      isExpanded: true,
                      underline: const SizedBox(),
                      style: TextStyle(
                        fontSize: 16,
                        color: isDark ? Colors.white : Colors.black,
                      ),
                      dropdownColor: isDark ? Colors.grey[800] : Colors.white,
                      hint: Text('اختر $label'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}