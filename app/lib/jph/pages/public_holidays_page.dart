import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../services/public_holidays_api.dart';
import '../widgets/app_background.dart';
import '../theme/app_colors.dart';
import '../l10n/app_localizations.dart';
import 'package:flutter/services.dart';
import '../widgets/glass_dialog.dart';

class PublicHolidaysPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const PublicHolidaysPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<PublicHolidaysPage> createState() => _PublicHolidaysPageState();
}

class _PublicHolidaysPageState extends State<PublicHolidaysPage> {
  bool _loading = true;
  bool _hasError = false;
  String _errorMessage = '';
  List<dynamic> _holidays = [];
  List<dynamic> _filteredHolidays = [];
  Map<String, dynamic> _stats = {
    'total': 0,
    'thisYear': 0,
    'nextYear': 0,
    'byType': {},
    'byMonth': {},
  };

  // Filter variables
  int _filterYear = DateTime.now().year;
  String _typeFilter = 'all';
  String _monthFilter = 'all';

  // For searching
  final TextEditingController _searchController = TextEditingController();
  bool _isSearching = false;

  // To track expanded state
  Map<String, bool> _expandedCards = {};

  // For add/edit form
  bool _showForm = false;
  bool _isEditing = false;
  String _editingId = '';
  final TextEditingController _fromDateController = TextEditingController();
  final TextEditingController _toDateController = TextEditingController();
  final TextEditingController _typeController = TextEditingController();
  final TextEditingController _descriptionController = TextEditingController();

  final List<String> _months = [
    'يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو',
    'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'
  ];

  @override
  void initState() {
    super.initState();
    _loadHolidays();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _fromDateController.dispose();
    _toDateController.dispose();
    _typeController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadHolidays() async {
    if (!mounted) return;

    setState(() {
      _loading = true;
      _hasError = false;
      _errorMessage = '';
    });

    try {
      print('📅 بدء تحميل العطلات الرسمية...');

      // جلب العطلات والإحصائيات معاً
      final [holidaysRes, statsRes] = await Future.wait([
        PublicHolidaysApi.getAllHolidays(),
        PublicHolidaysApi.getHolidaysStats(),
      ]);

      print('📊 استجابة API للعطلات: ${holidaysRes.toString()}');
      print('📊 استجابة API للإحصائيات: ${statsRes.toString()}');

      if (!mounted) return;

      if (holidaysRes["success"] == true && statsRes["success"] == true) {
        print('✅ تم تحميل البيانات بنجاح');
        print('📊 عدد العطلات: ${holidaysRes["holidays"]?.length ?? 0}');
        print('📊 الإحصائيات: ${statsRes["stats"]}');

        final holidays = List<dynamic>.from(holidaysRes["holidays"] ?? []);
        final stats = Map<String, dynamic>.from(statsRes["stats"] ?? {
          'total': 0,
          'thisYear': 0,
          'nextYear': 0,
          'byType': {},
          'byMonth': {},
        });

        // Initialize expanded state
        final newExpandedCards = <String, bool>{};
        for (var holiday in holidays) {
          final id = holiday['id']?.toString() ?? '';
          if (id.isNotEmpty) {
            newExpandedCards[id] = _expandedCards[id] ?? false;
          }
        }

        setState(() {
          _holidays = holidays;
          _filteredHolidays = List.from(holidays);
          _stats = stats;
          _loading = false;
          _expandedCards = newExpandedCards;
        });

        print('✅ تم تحميل ${_holidays.length} عطلة رسمية');
      } else {
        final errorMsg = holidaysRes["message"] ?? statsRes["message"] ?? "فشل في جلب البيانات";
        print('❌ فشل في جلب البيانات: $errorMsg');
        setState(() {
          _hasError = true;
          _errorMessage = errorMsg;
          _loading = false;
        });
      }
    } catch (e) {
      print('❌ خطأ غير متوقع في _loadHolidays: $e');
      if (!mounted) return;

      setState(() {
        _hasError = true;
        _errorMessage = "حدث خطأ في الاتصال بالخادم: $e";
        _loading = false;
      });
    }
  }

  List<String> _getUniqueHolidayTypes() {
    final types = <String>{};
    for (var holiday in _holidays) {
      final type = holiday['holidayType']?.toString().trim();
      if (type != null && type.isNotEmpty && type != 'null') {
        types.add(type);
      }
    }
    return types.toList()..sort();
  }

  void _applyFilters() {
    try {
      List<dynamic> filtered = List.from(_holidays);

      // Apply year filter
      filtered = filtered.where((holiday) {
        try {
          final fromDateStr = holiday['fromDate']?.toString() ?? '';
          if (fromDateStr.isEmpty) return false;

          final date = DateTime.parse(fromDateStr);
          return date.year == _filterYear;
        } catch (e) {
          return false;
        }
      }).toList();

      // Apply type filter
      if (_typeFilter != 'all') {
        filtered = filtered.where((holiday) {
          final type = holiday['holidayType']?.toString().trim() ?? '';
          return type == _typeFilter;
        }).toList();
      }

      // Apply month filter
      if (_monthFilter != 'all') {
        final monthIndex = _months.indexOf(_monthFilter);
        if (monthIndex != -1) {
          filtered = filtered.where((holiday) {
            try {
              final fromDateStr = holiday['fromDate']?.toString() ?? '';
              if (fromDateStr.isEmpty) return false;

              final date = DateTime.parse(fromDateStr);
              return date.month == monthIndex + 1;
            } catch (e) {
              return false;
            }
          }).toList();
        }
      }

      // Apply search filter
      if (_searchController.text.isNotEmpty) {
        final searchTerm = _searchController.text.toLowerCase();
        filtered = filtered.where((holiday) {
          final type = holiday['holidayType']?.toString().toLowerCase() ?? '';
          final description = holiday['description']?.toString().toLowerCase() ?? '';
          final fromDate = holiday['fromDate']?.toString().toLowerCase() ?? '';
          final toDate = holiday['toDate']?.toString().toLowerCase() ?? '';

          return type.contains(searchTerm) ||
              description.contains(searchTerm) ||
              fromDate.contains(searchTerm) ||
              toDate.contains(searchTerm);
        }).toList();
      }

      setState(() {
        _filteredHolidays = filtered;
      });
    } catch (e) {
      print('❌ خطأ في تطبيق الفلاتر: $e');
    }
  }

  void _resetFilters() {
    setState(() {
      _filterYear = DateTime.now().year;
      _typeFilter = 'all';
      _monthFilter = 'all';
      _searchController.clear();
      _filteredHolidays = List.from(_holidays);
    });
  }

  Future<void> _showFilterSheet() async {
    final appController = Provider.of<AppController>(context, listen: false);
    final isDark = appController.isDark;
    final uniqueTypes = _getUniqueHolidayTypes();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return Container(
              margin: const EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                  color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _SheetHeader(
                        title: AppLocalizations.of(context, 'filter_holidays'),
                        icon: Icons.filter_alt_rounded,
                        isDark: isDark,
                      ),
                      const SizedBox(height: 14),

                      // Year Picker
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark ? AppColors.primaryLight.withOpacity(0.3) : const Color(0xFFD7D3FF),
                            width: 1.4,
                          ),
                          color: isDark ? Colors.white.withOpacity(0.1) : const Color(0xFFF3F2FF),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizations.of(context, 'year'),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isDark ? AppColors.primaryLight.withOpacity(0.4) : AppColors.primary.withOpacity(0.4),
                                  width: 1.5,
                                ),
                                color: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
                              ),
                              child: DropdownButton<int>(
                                value: _filterYear,
                                isExpanded: true,
                                underline: const SizedBox(),
                                icon: Icon(
                                  Icons.arrow_drop_down_rounded,
                                  color: isDark ? AppColors.primaryLight : AppColors.primary,
                                  size: 28,
                                ),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                                dropdownColor: isDark ? const Color(0xFF2D2D2D) : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                onChanged: (int? newValue) {
                                  if (newValue != null) {
                                    setState(() {
                                      _filterYear = newValue;
                                    });
                                  }
                                },
                                items: List.generate(5, (index) {
                                  final year = DateTime.now().year - 2 + index;
                                  return DropdownMenuItem<int>(
                                    value: year,
                                    child: Text(year.toString()),
                                  );
                                }),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Type Filter (Dynamic from existing holidays)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark ? AppColors.primaryLight.withOpacity(0.3) : const Color(0xFFD7D3FF),
                            width: 1.4,
                          ),
                          color: isDark ? Colors.white.withOpacity(0.1) : const Color(0xFFF3F2FF),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizations.of(context, 'holiday_type'),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isDark ? AppColors.primaryLight.withOpacity(0.4) : AppColors.primary.withOpacity(0.4),
                                  width: 1.5,
                                ),
                                color: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
                              ),
                              child: DropdownButton<String>(
                                value: _typeFilter,
                                isExpanded: true,
                                underline: const SizedBox(),
                                icon: Icon(
                                  Icons.arrow_drop_down_rounded,
                                  color: isDark ? AppColors.primaryLight : AppColors.primary,
                                  size: 28,
                                ),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                                dropdownColor: isDark ? const Color(0xFF2D2D2D) : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                onChanged: (String? newValue) {
                                  setState(() {
                                    _typeFilter = newValue!;
                                  });
                                },
                                items: <String>['all', ...uniqueTypes]
                                    .map<DropdownMenuItem<String>>((String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(value == 'all' ? AppLocalizations.of(context, 'all') : value),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 14),

                      // Month Filter
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: isDark ? AppColors.primaryLight.withOpacity(0.3) : const Color(0xFFD7D3FF),
                            width: 1.4,
                          ),
                          color: isDark ? Colors.white.withOpacity(0.1) : const Color(0xFFF3F2FF),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              AppLocalizations.of(context, 'month'),
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isDark ? Colors.white70 : Colors.black54,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: isDark ? AppColors.primaryLight.withOpacity(0.4) : AppColors.primary.withOpacity(0.4),
                                  width: 1.5,
                                ),
                                color: isDark ? Colors.white.withOpacity(0.05) : Colors.white,
                              ),
                              child: DropdownButton<String>(
                                value: _monthFilter,
                                isExpanded: true,
                                underline: const SizedBox(),
                                icon: Icon(
                                  Icons.arrow_drop_down_rounded,
                                  color: isDark ? AppColors.primaryLight : AppColors.primary,
                                  size: 28,
                                ),
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: isDark ? Colors.white : Colors.black,
                                ),
                                dropdownColor: isDark ? const Color(0xFF2D2D2D) : Colors.white,
                                borderRadius: BorderRadius.circular(14),
                                onChanged: (String? newValue) {
                                  setState(() {
                                    _monthFilter = newValue!;
                                  });
                                },
                                items: <String>['all', ..._months]
                                    .map<DropdownMenuItem<String>>((String value) {
                                  return DropdownMenuItem<String>(
                                    value: value,
                                    child: Text(value == 'all' ? AppLocalizations.of(context, 'all') : value),
                                  );
                                }).toList(),
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 18),

                      // Filter Actions
                      _SheetActions(
                        onApply: () {
                          _applyFilters();
                          Navigator.pop(context);
                        },
                        onCancel: () {
                          _resetFilters();
                          Navigator.pop(context);
                        },
                        applyText: AppLocalizations.of(context, 'apply'),
                        cancelText: AppLocalizations.of(context, 'reset'),
                        isDark: isDark,
                      ),
                      const SizedBox(height: 10),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _showAddEditForm({Map<String, dynamic>? holiday}) async {
    _isEditing = holiday != null;
    _editingId = holiday?['id'] ?? '';

    if (_isEditing) {
      _fromDateController.text = holiday!['fromDate'] ?? '';
      _toDateController.text = holiday['toDate'] ?? '';
      _typeController.text = holiday['holidayType'] ?? '';
      _descriptionController.text = holiday['description'] ?? '';
    } else {
      _fromDateController.clear();
      _toDateController.clear();
      _typeController.clear();
      _descriptionController.clear();
    }

    setState(() {
      _showForm = true;
    });
  }

  Future<void> _selectDate(BuildContext context, bool isFromDate) async {
    final appController = Provider.of<AppController>(context, listen: false);
    final isRTL = appController.isRTL;

    final initialDate = isFromDate
        ? (_fromDateController.text.isNotEmpty
        ? DateTime.parse(_fromDateController.text)
        : DateTime.now())
        : (_toDateController.text.isNotEmpty
        ? DateTime.parse(_toDateController.text)
        : DateTime.now());

    final picked = await showDatePicker(
      context: context,
      initialDate: initialDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: ColorScheme.light(
              primary: appController.isDark ? AppColors.primaryLight : AppColors.primary,
            ),
            textButtonTheme: TextButtonThemeData(
              style: TextButton.styleFrom(
                foregroundColor: appController.isDark ? AppColors.primaryLight : AppColors.primary,
              ),
            ),
          ),
          child: Directionality(
            textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
            child: child!,
          ),
        );
      },
    );

    if (picked != null) {
      final formattedDate = DateFormat('yyyy-MM-dd').format(picked);
      if (isFromDate) {
        _fromDateController.text = formattedDate;
      } else {
        _toDateController.text = formattedDate;
      }
      setState(() {});
    }
  }

  Future<void> _saveHoliday() async {
    if (_fromDateController.text.isEmpty ||
        _toDateController.text.isEmpty ||
        _typeController.text.isEmpty) {
      _showErrorDialog(AppLocalizations.of(context, 'fill_required_fields'));
      return;
    }

    try {
      final fromDate = DateTime.parse(_fromDateController.text);
      final toDate = DateTime.parse(_toDateController.text);

      if (toDate.isBefore(fromDate)) {
        _showErrorDialog(AppLocalizations.of(context, 'to_date_before_from_date'));
        return;
      }
    } catch (e) {
      _showErrorDialog(AppLocalizations.of(context, 'invalid_date_format'));
      return;
    }

    setState(() {
      _loading = true;
    });

    try {
      Map<String, dynamic> result;

      if (_isEditing) {
        result = await PublicHolidaysApi.updateHoliday(
          holidayId: _editingId,
          fromDate: _fromDateController.text,
          toDate: _toDateController.text,
          holidayType: _typeController.text,
          description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        );
      } else {
        result = await PublicHolidaysApi.addHoliday(
          fromDate: _fromDateController.text,
          toDate: _toDateController.text,
          holidayType: _typeController.text,
          description: _descriptionController.text.isNotEmpty ? _descriptionController.text : null,
        );
      }

      if (!mounted) return;

      if (result["success"] == true) {
        _showSuccessDialog(result["message"] ??
            (_isEditing
                ? AppLocalizations.of(context, 'holiday_updated_success')
                : AppLocalizations.of(context, 'holiday_added_success')));

        // Reset form
        setState(() {
          _showForm = false;
          _isEditing = false;
          _editingId = '';
          _fromDateController.clear();
          _toDateController.clear();
          _typeController.clear();
          _descriptionController.clear();
        });

        // Reload holidays
        await _loadHolidays();
      } else {
        _showErrorDialog(result["message"] ?? AppLocalizations.of(context, 'operation_failed'));
      }
    } catch (e) {
      _showErrorDialog('${AppLocalizations.of(context, 'error_occurred')}: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _deleteHoliday(String holidayId) async {
    final appController = Provider.of<AppController>(context, listen: false);
    final isRTL = appController.isRTL;

    bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
        child: GlassAlertDialog(
          backgroundColor: appController.isDark ? Colors.grey[900] : Colors.white,
          title: Text(
            AppLocalizations.of(context, 'confirm_delete'),
            style: TextStyle(
              color: appController.isDark ? Colors.white : Colors.black,
              fontWeight: FontWeight.bold,
            ),
          ),
          content: Text(
            AppLocalizations.of(context, 'delete_holiday_confirmation'),
            style: TextStyle(
              color: appController.isDark ? Colors.white70 : Colors.grey[700],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(
                AppLocalizations.of(context, 'cancel'),
                style: TextStyle(
                  color: appController.isDark ? Colors.blue[300] : Colors.blue,
                ),
              ),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, true),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFEF5350),
                foregroundColor: Colors.white,
              ),
              child: Text(AppLocalizations.of(context, 'delete')),
            ),
          ],
        ),
      ),
    );

    if (confirm != true) return;

    setState(() {
      _loading = true;
    });

    try {
      final result = await PublicHolidaysApi.deleteHoliday(
        holidayId: holidayId,
      );

      if (!mounted) return;

      if (result["success"] == true) {
        _showSuccessDialog(result["message"] ?? AppLocalizations.of(context, 'holiday_deleted_success'));
        await _loadHolidays();
      } else {
        _showErrorDialog(result["message"] ?? AppLocalizations.of(context, 'delete_failed'));
      }
    } catch (e) {
      _showErrorDialog('${AppLocalizations.of(context, 'error_occurred')}: $e');
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _showErrorDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFD04545),
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
        backgroundColor: const Color(0xFF2E9B67),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _buildSearchBar(bool isDark, Color textColor) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Icon(
              Icons.search,
              color: isDark ? Colors.white70 : Colors.grey.shade600,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: _searchController,
                onChanged: (value) {
                  _applyFilters();
                },
                decoration: InputDecoration(
                  hintText: AppLocalizations.of(context, 'search_holidays'),
                  hintStyle: TextStyle(
                    color: isDark ? Colors.white60 : Colors.grey.shade600,
                  ),
                  border: InputBorder.none,
                ),
                style: TextStyle(
                  color: textColor,
                  fontSize: 14,
                ),
              ),
            ),
            if (_searchController.text.isNotEmpty)
              IconButton(
                onPressed: () {
                  _searchController.clear();
                  _applyFilters();
                },
                icon: Icon(
                  Icons.clear,
                  color: isDark ? Colors.white70 : Colors.grey.shade600,
                  size: 20,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddEditForm(bool isDark, bool isRTL, Color textColor, Color subduedTextColor, Color primaryColor) {
    return SingleChildScrollView(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _isEditing
                      ? AppLocalizations.of(context, 'edit_holiday')
                      : AppLocalizations.of(context, 'add_new_holiday'),
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                IconButton(
                  onPressed: () {
                    setState(() {
                      _showForm = false;
                      _isEditing = false;
                      _editingId = '';
                      _fromDateController.clear();
                      _toDateController.clear();
                      _typeController.clear();
                      _descriptionController.clear();
                    });
                  },
                  icon: Icon(
                    Icons.close,
                    color: textColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // From Date
            _buildFormField(
              label: AppLocalizations.of(context, 'from_date'),
              controller: _fromDateController,
              isDark: isDark,
              textColor: textColor,
              subduedTextColor: subduedTextColor,
              icon: Icons.calendar_today,
              onTap: () => _selectDate(context, true),
              isRequired: true,
            ),

            const SizedBox(height: 12),

            // To Date
            _buildFormField(
              label: AppLocalizations.of(context, 'to_date'),
              controller: _toDateController,
              isDark: isDark,
              textColor: textColor,
              subduedTextColor: subduedTextColor,
              icon: Icons.calendar_today,
              onTap: () => _selectDate(context, false),
              isRequired: true,
            ),

            const SizedBox(height: 12),

            // Holiday Type (Text Field instead of Dropdown)
            _buildFormField(
              label: AppLocalizations.of(context, 'holiday_type'),
              controller: _typeController,
              isDark: isDark,
              textColor: textColor,
              subduedTextColor: subduedTextColor,
              icon: Icons.event,
              onTap: null,
              isRequired: true,
              hintText: AppLocalizations.of(context, 'enter_holiday_type'),
            ),

            const SizedBox(height: 12),

            // Description
            _buildFormField(
              label: AppLocalizations.of(context, 'description'),
              controller: _descriptionController,
              isDark: isDark,
              textColor: textColor,
              subduedTextColor: subduedTextColor,
              icon: Icons.description,
              maxLines: 3,
              isRequired: false,
              hintText: AppLocalizations.of(context, 'enter_description'),
            ),

            const SizedBox(height: 24),

            // Save Button
            ElevatedButton(
              onPressed: _loading ? null : _saveHoliday,
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 54),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _loading
                  ? const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
                  : Text(
                _isEditing
                    ? AppLocalizations.of(context, 'update_holiday')
                    : AppLocalizations.of(context, 'save_holiday'),
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFormField({
    required String label,
    required TextEditingController controller,
    required bool isDark,
    required Color textColor,
    required Color subduedTextColor,
    required IconData icon,
    VoidCallback? onTap,
    int maxLines = 1,
    bool isRequired = false,
    String? hintText,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.2) : Colors.grey.shade300,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  icon,
                  color: subduedTextColor,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  '$label${isRequired ? ' *' : ''}',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: subduedTextColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              enabled: onTap == null,
              maxLines: maxLines,
              style: TextStyle(
                fontSize: 16,
                color: textColor,
              ),
              decoration: InputDecoration.collapsed(
                hintText: hintText ?? (onTap != null
                    ? AppLocalizations.of(context, 'tap_to_select')
                    : AppLocalizations.of(context, 'enter_text')),
                hintStyle: TextStyle(
                  color: subduedTextColor,
                ),
              ),
            ),
          ],
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

        final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark
            ? AppColors.onSurfaceVariantDark
            : AppColors.onSurfaceVariantLight;
        final cardColor = isDark ? Colors.white.withOpacity(0.15) : Colors.white;
        final dividerColor = isDark ? Colors.white.withOpacity(0.2) : Colors.grey.shade300;

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
                            AppLocalizations.of(context, 'public_holidays'),
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: _showFilterSheet,
                            icon: Container(
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
                                Icons.filter_alt_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                          if (widget.role == 'admin' || widget.role == 'المالك')
                            IconButton(
                              onPressed: () => _showAddEditForm(),
                              icon: Container(
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
                                  Icons.add,
                                  color: textColor,
                                  size: 22,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),

                    // Add/Edit Form
                    if (_showForm)
                      Expanded(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            child: _buildAddEditForm(isDark, isRTL, textColor, subduedTextColor, primaryColor),
                          ),
                        ),
                      ),

                    // Main Content (when form is not shown)
                    if (!_showForm)
                      Expanded(
                        child: SingleChildScrollView(
                          child: Column(
                            children: [
                              // Search Bar
                              _buildSearchBar(isDark, textColor),

                              const SizedBox(height: 8),

                              // 4 مربعات إحصائية
                              _buildStatsSection(isDark),

                              // Filter Info
                              if (_typeFilter != 'all' || _searchController.text.isNotEmpty || _monthFilter != 'all')
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    decoration: BoxDecoration(
                                      color: isDark ? Colors.blue.shade900.withOpacity(0.3) : Colors.blue.shade50,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          Icons.filter_alt_rounded,
                                          size: 16,
                                          color: isDark ? Colors.blue.shade300 : Colors.blue.shade700,
                                        ),
                                        const SizedBox(width: 8),
                                        Expanded(
                                          child: Text(
                                            _getFilterInfo(),
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: isDark ? Colors.blue.shade300 : Colors.blue.shade700,
                                            ),
                                          ),
                                        ),
                                        GestureDetector(
                                          onTap: _resetFilters,
                                          child: Text(
                                            AppLocalizations.of(context, 'clear'),
                                            style: TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.bold,
                                              color: isDark ? Colors.blue.shade300 : Colors.blue.shade700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),

                              const SizedBox(height: 8),

                              // قائمة العطلات
                              _buildHolidaysSection(
                                isDark: isDark,
                                isRTL: isRTL,
                                primaryColor: primaryColor,
                                textColor: textColor,
                                subduedTextColor: subduedTextColor,
                                cardColor: cardColor,
                                dividerColor: dividerColor,
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

  String _getFilterInfo() {
    List<String> filters = [];

    if (_typeFilter != 'all') {
      filters.add('${AppLocalizations.of(context, 'type')}: $_typeFilter');
    }

    if (_monthFilter != 'all') {
      filters.add('${AppLocalizations.of(context, 'month')}: $_monthFilter');
    }

    if (_searchController.text.isNotEmpty) {
      filters.add('${AppLocalizations.of(context, 'search')}: ${_searchController.text}');
    }

    filters.add('${AppLocalizations.of(context, 'year')}: $_filterYear');

    return filters.join(' • ');
  }

  Widget _buildStatsSection(bool isDark) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        children: [
          // صف الإحصائيات العليا
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                // إجمالي العطلات
                _buildStatCard(
                  title: AppLocalizations.of(context, 'total_holidays'),
                  count: _stats['total']?.toString() ?? '0',
                  icon: Icons.event_available_rounded,
                  iconColor: AppColors.primary,
                  bgColor: isDark ? AppColors.primary.withOpacity(0.2) : AppColors.primary.withOpacity(0.1),
                  isDark: isDark,
                ),
                const SizedBox(width: 8),

                // عطلات السنة الحالية
                _buildStatCard(
                  title: AppLocalizations.of(context, 'this_year'),
                  count: _stats['thisYear']?.toString() ?? '0',
                  icon: Icons.calendar_today_rounded,
                  iconColor: const Color(0xFF2196F3),
                  bgColor: isDark ? const Color(0xFF2196F3).withOpacity(0.2) : const Color(0xFFE3F2FD),
                  isDark: isDark,
                ),
                const SizedBox(width: 8),

                // عطلات السنة القادمة
                _buildStatCard(
                  title: AppLocalizations.of(context, 'next_year'),
                  count: _stats['nextYear']?.toString() ?? '0',
                  icon: Icons.calendar_month_rounded,
                  iconColor: const Color(0xFFFF9800),
                  bgColor: isDark ? const Color(0xFFFF9800).withOpacity(0.2) : const Color(0xFFFFF3E0),
                  isDark: isDark,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),

          // أهم أنواع العطلات
          if ((_stats['byType'] as Map).isNotEmpty)
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: (_stats['byType'] as Map).entries.take(4).map((entry) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _buildStatCard(
                      title: entry.key,
                      count: entry.value.toString(),
                      icon: _getHolidayTypeIcon(entry.key),
                      iconColor: _getHolidayTypeColor(entry.key),
                      bgColor: isDark
                          ? _getHolidayTypeColor(entry.key).withOpacity(0.2)
                          : _getHolidayTypeColor(entry.key).withOpacity(0.1),
                      isDark: isDark,
                    ),
                  );
                }).toList(),
              ),
            ),
        ],
      ),
    );
  }

  IconData _getHolidayTypeIcon(String type) {
    switch (type.toLowerCase()) {
      case 'راس السنة':
      case 'رأس السنة':
        return Icons.celebration_rounded;
      case 'عيد الميلاد':
        return Icons.church_rounded;
      case 'عيد الفطر':
        return Icons.mosque_rounded;
      case 'عيد الأضحى':
        return Icons.grass_rounded;
      default:
        return Icons.event_rounded;
    }
  }

  Color _getHolidayTypeColor(String type) {
    switch (type.toLowerCase()) {
      case 'راس السنة':
      case 'رأس السنة':
        return const Color(0xFF2196F3);
      case 'عيد الميلاد':
        return const Color(0xFF4CAF50);
      case 'عيد الفطر':
        return const Color(0xFFFF9800);
      case 'عيد الأضحى':
        return const Color(0xFFEF5350);
      default:
        return const Color(0xFF9C27B0);
    }
  }

  Widget _buildHolidaysSection({
    required bool isDark,
    required bool isRTL,
    required Color primaryColor,
    required Color textColor,
    required Color subduedTextColor,
    required Color cardColor,
    required Color dividerColor,
  }) {
    if (_loading) {
      return Container(
        height: 200,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(color: primaryColor),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context, 'loading_holidays'),
                style: TextStyle(
                  color: subduedTextColor,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_hasError) {
      return Container(
        height: 200,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.error_outline_rounded,
                size: 64,
                color: const Color(0xFFEF5350),
              ),
              const SizedBox(height: 16),
              Text(
                _errorMessage,
                style: TextStyle(
                  fontSize: 16,
                  color: const Color(0xFFEF5350),
                  fontWeight: FontWeight.w600,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _loadHolidays,
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(AppLocalizations.of(context, 'retry')),
              ),
            ],
          ),
        ),
      );
    }

    if (_filteredHolidays.isEmpty) {
      return Container(
        height: 200,
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.event_available_rounded,
                size: 64,
                color: subduedTextColor,
              ),
              const SizedBox(height: 16),
              Text(
                AppLocalizations.of(context, 'no_holidays'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: subduedTextColor,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _searchController.text.isNotEmpty || _typeFilter != 'all' || _monthFilter != 'all'
                    ? AppLocalizations.of(context, 'no_results_found')
                    : AppLocalizations.of(context, 'no_holidays_registered'),
                style: TextStyle(
                  fontSize: 14,
                  color: subduedTextColor,
                ),
              ),
              if (_searchController.text.isNotEmpty || _typeFilter != 'all' || _monthFilter != 'all')
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: ElevatedButton(
                    onPressed: _resetFilters,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: primaryColor,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(AppLocalizations.of(context, 'reset_filters')),
                  ),
                ),
            ],
          ),
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _loadHolidays,
      color: primaryColor,
      child: ListView.builder(
        shrinkWrap: true,
        physics: NeverScrollableScrollPhysics(),
        itemCount: _filteredHolidays.length,
        itemBuilder: (context, index) {
          final holiday = _filteredHolidays[index];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: _buildHolidayCard(
              holiday: holiday,
              index: index,
              isDark: isDark,
              textColor: textColor,
              subduedTextColor: subduedTextColor,
              cardColor: cardColor,
              dividerColor: dividerColor,
            ),
          );
        },
      ),
    );
  }

  Widget _buildStatCard({
    required String title,
    required String count,
    required IconData icon,
    required Color iconColor,
    required Color bgColor,
    required bool isDark,
  }) {
    return Container(
      width: 120,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 6,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: isDark ? Colors.white.withOpacity(0.1) : Colors.white.withOpacity(0.7),
            ),
            child: Icon(icon, color: iconColor, size: 20),
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isDark ? Colors.white70 : Colors.grey.shade700,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            count,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w900,
              color: iconColor,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildHolidayCard({
    required Map<String, dynamic> holiday,
    required int index,
    required bool isDark,
    required Color textColor,
    required Color subduedTextColor,
    required Color cardColor,
    required Color dividerColor,
  }) {
    final fromDateStr = holiday['fromDate']?.toString() ?? '';
    final toDateStr = holiday['toDate']?.toString() ?? '';
    final holidayType = holiday['holidayType']?.toString() ?? AppLocalizations.of(context, 'unknown');
    final description = holiday['description']?.toString() ?? '';

    DateTime? fromDate;
    DateTime? toDate;
    String formattedFromDate = '';
    String formattedToDate = '';
    String duration = '';

    try {
      if (fromDateStr.isNotEmpty) {
        fromDate = DateTime.parse(fromDateStr);
        formattedFromDate = DateFormat('dd/MM/yyyy').format(fromDate);
      }
      if (toDateStr.isNotEmpty) {
        toDate = DateTime.parse(toDateStr);
        formattedToDate = DateFormat('dd/MM/yyyy').format(toDate);
      }
      if (fromDate != null && toDate != null) {
        final diff = toDate.difference(fromDate).inDays + 1;
        duration = diff == 1
            ? AppLocalizations.of(context, 'one_day')
            : '${diff.toString()} ${AppLocalizations.of(context, 'days')}';
      }
    } catch (e) {
      print('❌ خطأ في تحليل التاريخ: $e');
    }

    final cardId = holiday['id']?.toString() ?? 'card_$index';
    final isExpanded = _expandedCards[cardId] ?? false;

    return GestureDetector(
      onTap: () {
        setState(() {
          _expandedCards[cardId] = !isExpanded;
        });
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.08),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
          border: Border.all(
            color: isDark ? Colors.white.withOpacity(0.1) : Colors.grey.shade200,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                // Holiday Type with icon
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: _getHolidayTypeColor(holidayType).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _getHolidayTypeColor(holidayType).withOpacity(0.3)),
                  ),
                  child: Row(
                    children: [
                      Icon(_getHolidayTypeIcon(holidayType), size: 16, color: _getHolidayTypeColor(holidayType)),
                      const SizedBox(width: 6),
                      Text(
                        holidayType,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: _getHolidayTypeColor(holidayType),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const Spacer(),

                // Duration
                Text(
                  duration,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: subduedTextColor,
                  ),
                ),
                const SizedBox(width: 12),

                // Expand/Collapse icon
                Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  color: subduedTextColor,
                  size: 24,
                ),
              ],
            ),

            const SizedBox(height: 12),

            // Dates
            Row(
              children: [
                Icon(
                  Icons.calendar_month_rounded,
                  size: 18,
                  color: subduedTextColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$formattedFromDate - $formattedToDate',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: textColor,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 8),

            // Description Preview
            if (description.isNotEmpty)
              Text(
                description,
                style: TextStyle(
                  fontSize: 14,
                  color: textColor,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),

            // Action Buttons (for admin/ceo)
            if (widget.role == 'admin' || widget.role == 'المالك') ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _showAddEditForm(holiday: holiday),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue.withOpacity(0.1),
                        foregroundColor: Colors.blue,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.blue.withOpacity(0.3)),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.edit_rounded, size: 18),
                          const SizedBox(width: 8),
                          Text(AppLocalizations.of(context, 'edit')),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: () => _deleteHoliday(holiday['id']),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red.withOpacity(0.1),
                        foregroundColor: Colors.red,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Colors.red.withOpacity(0.3)),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.delete_rounded, size: 18),
                          const SizedBox(width: 8),
                          Text(AppLocalizations.of(context, 'delete')),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],

            // EXPANDED CONTENT
            if (isExpanded) ...[
              Divider(
                color: dividerColor,
                height: 1,
              ),
              const SizedBox(height: 12),

              // Full Description
              if (description.isNotEmpty)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      AppLocalizations.of(context, 'description'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: subduedTextColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(
                        fontSize: 14,
                        color: textColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                ),

              // Year and Month
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context, 'year'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: subduedTextColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fromDate?.year.toString() ?? '',
                          style: TextStyle(
                            fontSize: 14,
                            color: textColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          AppLocalizations.of(context, 'month'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: subduedTextColor,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          fromDate != null ? _months[fromDate!.month - 1] : '',
                          style: TextStyle(
                            fontSize: 14,
                            color: textColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),

              // Day of Week
              if (fromDate != null)
                Row(
                  children: [
                    Icon(
                      Icons.calendar_view_day_rounded,
                      size: 16,
                      color: subduedTextColor,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      DateFormat('EEEE', AppLocalizations.of(context, 'locale')).format(fromDate!),
                      style: TextStyle(
                        fontSize: 14,
                        color: textColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// ================== Shared Widgets for Filter Sheet ==================
class _SheetHeader extends StatelessWidget {
  final String title;
  final IconData icon;
  final bool isDark;

  const _SheetHeader({
    required this.title,
    required this.icon,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFEDEBFF),
          ),
          child: Icon(
            icon,
            color: isDark ? AppColors.primaryLight : AppColors.primary,
            size: 26,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                color: isDark ? Colors.white : Colors.black,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SheetActions extends StatelessWidget {
  final VoidCallback onApply;
  final VoidCallback onCancel;
  final String applyText;
  final String cancelText;
  final bool isDark;

  const _SheetActions({
    required this.onApply,
    required this.onCancel,
    required this.applyText,
    required this.cancelText,
    required this.isDark,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;

    return Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 52,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                elevation: 0,
              ),
              onPressed: onApply,
              child: Text(
                applyText,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: SizedBox(
            height: 52,
            child: TextButton(
              onPressed: onCancel,
              child: Text(
                cancelText,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                  color: isDark ? Colors.white : Colors.black,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
