import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../services/employees_api.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';

class EmployeeDetailsPage extends StatefulWidget {
  final Map<String, dynamic> employeeData;
  final String currentUserId;
  final String currentUserName;
  final String currentUserRole;

  const EmployeeDetailsPage({
    super.key,
    required this.employeeData,
    required this.currentUserId,
    required this.currentUserName,
    required this.currentUserRole,
  });

  @override
  State<EmployeeDetailsPage> createState() => _EmployeeDetailsPageState();
}

class _EmployeeDetailsPageState extends State<EmployeeDetailsPage> {
  late Map<String, dynamic> _employeeData;
  bool _isEditing = false;
  bool _isLoading = false;
  File? _selectedImage;
  final ImagePicker _picker = ImagePicker();

  // تحكمات النماذج
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _dailyRateController = TextEditingController();
  final TextEditingController _salaryController = TextEditingController();
  final TextEditingController _joinDateController = TextEditingController();
  final TextEditingController _foremanIdController = TextEditingController();
  final TextEditingController _startSalaryController = TextEditingController();
  final TextEditingController _increaseController = TextEditingController();
  final TextEditingController _levelController = TextEditingController();
  final TextEditingController _workHoursController = TextEditingController();

  // متغيرات القوائم المنسدلة
  String? _selectedRole;
  String? _selectedAccounting;
  String? _selectedManagedBy;
  String? _selectedLeaveDay;
  String? _selectedAbsenceMultiplier;
  String? _selectedOvertimeMultiplier;
  String? _selectedStatus;
  bool _isActive = true;

  // قوائم الخيارات
  final List<String> _roles = ['صاحب عمل', 'صنايعي', 'عامل', 'فورمن', 'سوبرفايزر'];
  final List<String> _accountingTypes = ['شهرى', 'يومى'];
  final List<String> _leaveDays = ["الأحد", "الاثنين", "الثلاثاء", "الأربعاء", "الخميس", "الجمعة", "السبت"];
  final List<String> _workHoursList = ['10 ساعات', '9 ساعات', '8 ساعات', '7 ساعات', '6 ساعات'];
  final List<String> _multipliers = ['1', '1.25', '1.5', '2'];
  final List<String> _statuses = ['على رأس العمل', 'تم التصفيه', 'مغادر', 'إجازة'];

  List<Map<String, dynamic>> _ownersList = [];

  @override
  void initState() {
    super.initState();
    _employeeData = Map.from(widget.employeeData);
    _initializeControllers();
    _initializeDropdownValues();
    _fetchOwners();
  }

  void _initializeControllers() {
    _nameController.text = _employeeData['name']?.toString() ?? '';
    _phoneController.text = _employeeData['phone']?.toString() ?? '';
    _emailController.text = _employeeData['email']?.toString() ?? '';
    _dailyRateController.text = _employeeData['dailyRate']?.toString() ?? '';
    _salaryController.text = _employeeData['salary']?.toString() ?? '';
    _joinDateController.text = _employeeData['joinDate']?.toString() ?? '';
    _foremanIdController.text = _employeeData['foremanId']?.toString() ?? '';
    _startSalaryController.text = _employeeData['startSalary']?.toString() ?? '';
    _increaseController.text = _employeeData['increase']?.toString() ?? '';
    _levelController.text = _employeeData['level']?.toString() ?? '';
    _workHoursController.text = _employeeData['workHours']?.toString() ?? '';
    _isActive = _employeeData['active'] == true;
  }

  void _initializeDropdownValues() {
    _selectedRole = _employeeData['role']?.toString();
    _selectedAccounting = _employeeData['accounting']?.toString();
    _selectedManagedBy = _employeeData['managedBy']?.toString();
    _selectedLeaveDay = _employeeData['leaveDay']?.toString();
    _selectedAbsenceMultiplier = _employeeData['absenceMultiplier']?.toString();
    _selectedOvertimeMultiplier = _employeeData['overtimeMultiplier']?.toString();
    _selectedStatus = _employeeData['status']?.toString();
  }

  Future<void> _fetchOwners() async {
    try {
      final response = await EmployeesApi.getAllEmployees();
      if (response["success"] == true) {
        List<dynamic> employees = response["employees"] ?? [];
        List<Map<String, dynamic>> owners = [];
        for (var emp in employees) {
          if (emp['role'] == 'صاحب عمل') {
            owners.add({
              'uid': emp['uid']?.toString(),
              'name': emp['name']?.toString(),
            });
          }
        }
        setState(() {
          _ownersList = owners;
        });
      } else {
        print('Failed to fetch employees: ${response["message"]}');
        setState(() {
          _ownersList = [];
        });
      }
    } catch (e) {
      print('Error fetching owners: $e');
      setState(() {
        _ownersList = [];
      });
    }
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

  Future<void> _updateEmployee() async {
    // التحقق من صلاحيات المستخدم لتعديل بيانات صاحب عمل
    if (_selectedRole == 'صاحب عمل' && widget.currentUserId != _employeeData['uid']) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('لا يمكنك تعديل بيانات صاحب عمل آخر'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    try {
      setState(() {
        _isLoading = true;
      });

      final updateData = {
        'name': _nameController.text.trim(),
        'phone': _phoneController.text.trim(),
        'email': _emailController.text.trim(),
        'role': _selectedRole,
        'dailyRate': _dailyRateController.text.trim(),
        'salary': _salaryController.text.trim(),
        'joinDate': _joinDateController.text.trim(),
        'accounting': _selectedAccounting,
        'managedBy': _selectedManagedBy,
        'foremanId': _foremanIdController.text.trim(),
        'startSalary': _startSalaryController.text.trim(),
        'increase': _increaseController.text.trim(),
        'leaveDay': _selectedLeaveDay,
        'workHours': _selectedAccounting == 'شهرى' ? _workHoursController.text.trim() : '',
        'absenceMultiplier': _selectedAbsenceMultiplier,
        'overtimeMultiplier': _selectedOvertimeMultiplier,
        'level': _levelController.text.trim(),
        'status': _selectedStatus,
        'active': _isActive,
      };

      final response = await EmployeesApi.updateEmployee(
        uid: _employeeData['uid']?.toString() ?? '',
        data: updateData,
      );

      if (response["success"] == true && mounted) {
        if (_selectedImage != null) {
          final bytes = await _selectedImage!.readAsBytes();
          final base64Image = String.fromCharCodes(bytes);

          await EmployeesApi.updateEmployeePhoto(
            uid: _employeeData['uid']?.toString() ?? '',
            imageBase64: base64Image,
          );
        }

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('تم تحديث بيانات الموظف بنجاح'),
            backgroundColor: Colors.green,
          ),
        );

        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response["message"] ?? 'فشل في تحديث البيانات'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في التحديث: $e'),
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

  Future<void> _toggleEmployeeStatus() async {
    try {
      setState(() {
        _isLoading = true;
      });

      final response = await EmployeesApi.changeEmployeeStatus(
        uid: _employeeData['uid']?.toString() ?? '',
        active: !_isActive,
      );

      if (response["success"] == true && mounted) {
        setState(() {
          _isActive = !_isActive;
          _employeeData['active'] = _isActive;
        });

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _isActive ? 'تم تفعيل حساب الموظف' : 'تم تعطيل حساب الموظف',
            ),
            backgroundColor: _isActive ? Colors.green : Colors.orange,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(response["message"] ?? 'فشل في تغيير الحالة'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('خطأ في تغيير الحالة: $e'),
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

  // دالة لتحضير قائمة أسماء المدراء بدون تكرارات
  List<String> _getOwnerNames() {
    Set<String> uniqueNames = {};
    List<String> names = [];

    for (var owner in _ownersList) {
      String name = owner['name']?.toString() ?? '';
      if (name.isNotEmpty && !uniqueNames.contains(name)) {
        uniqueNames.add(name);
        names.add(name);
      }
    }

    return names;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;
        final photo = _employeeData['photo']?.toString() ?? '';

        // التحقق مما إذا كان المستخدم الحالي يمكنه تعديل بيانات هذا الموظف
        final bool canEdit = widget.currentUserRole == 'صاحب عمل' &&
            widget.currentUserId == _employeeData['uid'];
        final bool isViewingOwner = _employeeData['role'] == 'صاحب عمل';
        final bool canToggleEdit = _isEditing || canEdit || !isViewingOwner;

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
                              _isEditing ? 'تعديل بيانات الموظف' : 'تفاصيل الموظف',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: isDark ? Colors.white : Colors.black,
                              ),
                            ),
                          ),
                          // إظهار زر التعديل فقط إذا كان المستخدم الحالي هو صاحب العمل نفسه أو الموظف ليس صاحب عمل
                          if (!_isEditing && canToggleEdit)
                            IconButton(
                              icon: Icon(
                                Icons.edit,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                              onPressed: () {
                                if (isViewingOwner && !canEdit) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(
                                      content: Text('لا يمكنك تعديل بيانات صاحب عمل آخر'),
                                      backgroundColor: Colors.red,
                                    ),
                                  );
                                } else {
                                  setState(() {
                                    _isEditing = true;
                                  });
                                }
                              },
                            ),
                          if (_isEditing)
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                              onPressed: () {
                                setState(() {
                                  _isEditing = false;
                                  _selectedImage = null;
                                  _initializeControllers();
                                  _initializeDropdownValues();
                                });
                              },
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
                                onTap: _isEditing && canToggleEdit ? _pickImage : null,
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
                                            : photo.isNotEmpty
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
                                            return _buildDefaultAvatar(_nameController.text, isDark);
                                          },
                                        )
                                            : _buildDefaultAvatar(_nameController.text, isDark),
                                      ),
                                    ),
                                    if (_isEditing && canToggleEdit)
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
                              label: 'الاسم',
                              value: _nameController,
                              icon: Icons.person,
                              isEditable: _isEditing && canToggleEdit,
                            ),
                            _buildInfoField(
                              label: 'رقم الهاتف',
                              value: _phoneController,
                              icon: Icons.phone,
                              isEditable: _isEditing && canToggleEdit,
                              keyboardType: TextInputType.phone,
                            ),
                            _buildInfoField(
                              label: 'البريد الإلكتروني',
                              value: _emailController,
                              icon: Icons.email,
                              isEditable: _isEditing && canToggleEdit,
                              keyboardType: TextInputType.emailAddress,
                            ),
                            _buildDropdownField(
                              label: 'الدور',
                              value: _selectedRole,
                              items: _roles,
                              icon: Icons.work,
                              isEditable: _isEditing && canToggleEdit,
                              onChanged: (value) {
                                setState(() {
                                  _selectedRole = value;
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
                              label: 'المحاسبه',
                              value: _selectedAccounting,
                              items: _accountingTypes,
                              icon: Icons.account_balance,
                              isEditable: _isEditing && canToggleEdit,
                              onChanged: (value) {
                                setState(() {
                                  _selectedAccounting = value;
                                });
                              },
                              isDark: isDark,
                            ),

                            _buildDropdownField(
                              label: 'يتبع لـ',
                              value: _selectedManagedBy,
                              items: _getOwnerNames(),
                              icon: Icons.supervisor_account,
                              isEditable: _isEditing && canToggleEdit,
                              onChanged: (value) {
                                setState(() {
                                  _selectedManagedBy = value;
                                });
                              },
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
                                label: 'الأجر اليومي',
                                value: _dailyRateController,
                                icon: Icons.attach_money,
                                isEditable: _isEditing && canToggleEdit,
                                keyboardType: TextInputType.number,
                              ),
                            if (_selectedAccounting == 'شهرى') ...[
                              _buildInfoField(
                                label: 'الراتب الشهري',
                                value: _salaryController,
                                icon: Icons.account_balance_wallet,
                                isEditable: false, // لا يعدل
                                keyboardType: TextInputType.number,
                              ),
                              _buildInfoField(
                                label: 'راتب البداية',
                                value: _startSalaryController,
                                icon: Icons.money,
                                isEditable: _isEditing && canToggleEdit,
                                keyboardType: TextInputType.number,
                              ),
                              _buildInfoField(
                                label: 'الزيادة',
                                value: _increaseController,
                                icon: Icons.trending_up,
                                isEditable: false, // لا تعدل
                                keyboardType: TextInputType.number,
                              ),
                            ],

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
                                isEditable: _isEditing && canToggleEdit,
                                onChanged: (value) {
                                  setState(() {
                                    _selectedLeaveDay = value;
                                  });
                                },
                                isDark: isDark,
                              ),
                              _buildDropdownField(
                                label: 'ساعات العمل',
                                value: _workHoursController.text,
                                items: _workHoursList,
                                icon: Icons.access_time,
                                isEditable: _isEditing && canToggleEdit,
                                onChanged: (value) {
                                  setState(() {
                                    _workHoursController.text = value ?? '';
                                  });
                                },
                                isDark: isDark,
                              ),
                            ],
                            _buildDropdownField(
                              label: 'مضروب الغياب',
                              value: _selectedAbsenceMultiplier,
                              items: _multipliers,
                              icon: Icons.calculate,
                              isEditable: _isEditing && canToggleEdit,
                              onChanged: (value) {
                                setState(() {
                                  _selectedAbsenceMultiplier = value;
                                });
                              },
                              isDark: isDark,
                            ),
                            _buildDropdownField(
                              label: 'مضروب الأوفرتايم',
                              value: _selectedOvertimeMultiplier,
                              items: _multipliers,
                              icon: Icons.calculate,
                              isEditable: _isEditing && canToggleEdit,
                              onChanged: (value) {
                                setState(() {
                                  _selectedOvertimeMultiplier = value;
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

                            _buildInfoField(
                              label: 'المستوى',
                              value: _levelController,
                              icon: Icons.star,
                              isEditable: false, // لا يعدل
                            ),
                            _buildDropdownField(
                              label: 'الوضع',
                              value: _selectedStatus,
                              items: _statuses,
                              icon: Icons.work,
                              isEditable: _isEditing && canToggleEdit,
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
                                  if (_isEditing && canToggleEdit)
                                    Switch(
                                      value: _isActive,
                                      onChanged: (value) {
                                        setState(() {
                                          _isActive = value;
                                        });
                                      },
                                      activeColor: Colors.green,
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                      decoration: BoxDecoration(
                                        color: _isActive
                                            ? (isDark ? Colors.green.withOpacity(0.2) : Colors.green.withOpacity(0.1))
                                            : (isDark ? Colors.red.withOpacity(0.2) : Colors.red.withOpacity(0.1)),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        _isActive ? 'نشط' : 'غير نشط',
                                        style: TextStyle(
                                          color: _isActive
                                              ? (isDark ? Colors.green[300] : Colors.green[800])
                                              : (isDark ? Colors.red[300] : Colors.red[800]),
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),

                            const SizedBox(height: 32),

                            // أزرار التحكم
                            if (_isEditing)
                              Column(
                                children: [
                                  SizedBox(
                                    width: double.infinity,
                                    child: ElevatedButton(
                                      onPressed: () {
                                        if (_selectedRole == 'صاحب عمل' && widget.currentUserId != _employeeData['uid']) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('لا يمكنك تعديل بيانات صاحب عمل آخر'),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                        } else {
                                          _updateEmployee();
                                        }
                                      },
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: AppColors.primary,
                                        padding: const EdgeInsets.symmetric(vertical: 16),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                      ),
                                      child: const Text(
                                        'حفظ التغييرات',
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
                                        setState(() {
                                          _isEditing = false;
                                          _selectedImage = null;
                                          _initializeControllers();
                                          _initializeDropdownValues();
                                        });
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
                              )
                            else if (canToggleEdit) // إظهار زر تغيير الحالة فقط للمستخدمين المسموح لهم
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _toggleEmployeeStatus,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: _isActive ? Colors.orange : Colors.green,
                                    padding: const EdgeInsets.symmetric(vertical: 16),
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                  ),
                                  child: Text(
                                    _isActive ? 'تعطيل تسجيل الدخول' : 'تفعيل تسجيل الدخول',
                                    style: const TextStyle(
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
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

  Widget _buildDefaultAvatar(String name, bool isDark) {
    return Center(
      child: Text(
        name.isNotEmpty ? name[0] : '?',
        style: TextStyle(
          fontSize: 40,
          fontWeight: FontWeight.bold,
          color: isDark ? Colors.white70 : Colors.grey[700],
        ),
      ),
    );
  }

  Widget _buildInfoField({
    required String label,
    required TextEditingController value,
    required IconData icon,
    required bool isEditable,
    bool enabled = true,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;

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
                        child: isEditable
                            ? TextField(
                          controller: value,
                          keyboardType: keyboardType,
                          enabled: enabled,
                          style: TextStyle(
                            fontSize: 16,
                            color: isDark ? Colors.white : Colors.black,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 16),
                          ),
                        )
                            : Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            value.text.isNotEmpty ? value.text : 'غير محدد',
                            style: TextStyle(
                              fontSize: 16,
                              color: isDark ? Colors.white : Colors.black,
                            ),
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
      },
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
                    child: _isEditing
                        ? InkWell(
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
                    )
                        : Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        _joinDateController.text.isNotEmpty ? _joinDateController.text : 'غير محدد',
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black,
                        ),
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
                    child: !_isEditing
                        ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        value ?? 'غير محدد',
                        style: TextStyle(
                          fontSize: 16,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                      ),
                    )
                        : DropdownButton<String>(
                      value: filteredItems.contains(value) ? value : null,
                      items: filteredItems.map((item) {
                        return DropdownMenuItem<String>(
                          value: item,
                          child: Text(item),
                        );
                      }).toList(),
                      onChanged: isEditable ? onChanged : null,
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