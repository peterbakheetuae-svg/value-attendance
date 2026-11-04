import 'api_service.dart';

class AttendanceReportMonthlyApi {
  /// جلب التقرير الشهري من شيت Labor Summary via server JS
  static Future<Map<String, dynamic>> fetch({
    required String uid,
    required int year,
    required String month, // شهر عربي: ديسمبر – يناير – ...
  }) async {
    try {
      final response = await ApiService.post({
        "action": "attendance_report_monthly",
        "uid": uid,
        "year": year.toString(),
        "month": month,
      });

      // ✅ تحويل البيانات من String إلى int/double عند الضرورة
      if (response["success"] == true && response["report"] != null) {
        response["report"] = _convertReportData(response["report"]);
      }

      return response;
    } catch (e) {
      return {
        "success": false,
        "message": "خطأ في الاتصال: $e",
        "report": {},
      };
    }
  }

  // ✅ دالة مساعدة لتحويل بيانات التقرير
  static Map<String, dynamic> _convertReportData(dynamic reportData) {
    if (reportData is! Map<String, dynamic>) {
      return {};
    }

    final Map<String, dynamic> converted = {};

    // قائمة بالمفاتيح التي يجب أن تكون أرقاماً (int)
    const intKeys = [
      'workDays', 'holidayAttend', 'holidays', 'sick', 'absent'
    ];

    // قائمة بالمفاتيح التي يجب أن تكون أرقاماً (double) أو مالية
    const doubleKeys = [
      'lateAmount', 'attendSalary', 'allowance', 'bonus',
      'workExpenses', 'deduction', 'absentDeduction', 'advance',
      'received', 'dueSalary', 'arrears'
    ];

    // قائمة بالمفاتيح التي تبقى كـ String
    const stringKeys = ['lateHours'];

    // دالة مساعدة لتحويل النص العربي إلى double
    double _parseArabicNumber(dynamic value) {
      if (value == null) return 0.0;

      String text = value.toString().trim();
      if (text.isEmpty) return 0.0;

      // 1. تحويل الأرقام العربية والفارسية إلى إنجليزية
      const arabicDigits = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
      const persianDigits = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];

      for (int i = 0; i < arabicDigits.length; i++) {
        text = text.replaceAll(arabicDigits[i], i.toString());
      }
      for (int i = 0; i < persianDigits.length; i++) {
        text = text.replaceAll(persianDigits[i], i.toString());
      }

      // 2. إزالة فواصل الآلاف (العربية والإنجليزية)
      text = text.replaceAll('٬', '').replaceAll(',', '');

      // 3. استبدال الفاصلة العشرية العربية بالنقطة
      text = text.replaceAll('٫', '.');
      text = text.replaceAll('،', '.');

      // 4. إزالة أي رموز عملة أو أحرف غير رقمية باستثناء النقطة والعلامة السالبة
      text = text.replaceAll(RegExp(r'[^0-9\.\-]'), '');

      // 5. محاولة التحويل إلى double
      return double.tryParse(text) ?? 0.0;
    }

    for (final key in reportData.keys) {
      final value = reportData[key];

      if (intKeys.contains(key)) {
        // تحويل إلى int
        if (value is String) {
          // أولاً نحول إلى double ثم إلى int
          final doubleVal = _parseArabicNumber(value);
          converted[key] = doubleVal.toInt();
        } else if (value is int) {
          converted[key] = value;
        } else if (value is double) {
          converted[key] = value.toInt();
        } else {
          converted[key] = 0;
        }
      } else if (doubleKeys.contains(key)) {
        // تحويل إلى double
        if (value is String) {
          converted[key] = _parseArabicNumber(value);
        } else if (value is double) {
          converted[key] = value;
        } else if (value is int) {
          converted[key] = value.toDouble();
        } else {
          converted[key] = 0.0;
        }
      } else if (stringKeys.contains(key)) {
        // تركها كـ String (خاصة وقت الإضافي)
        converted[key] = value?.toString() ?? '';
      } else {
        // باقي المفاتيح نتركها كما هي
        converted[key] = value;
      }
    }

    return converted;
  }
}