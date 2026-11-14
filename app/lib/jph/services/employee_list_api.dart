import 'api_service.dart';

class EmployeeListApi {
  /// [all]: also the stopped accounts (HR only)
  static Future<Map<String, dynamic>> fetch({bool all = false}) async {
    try {
      final response = await ApiService.post({
        "action": all ? "get_all_employees" : "employee_list",
      });

      return response;
    } catch (e) {
      return {
        "success": false,
        "message": "خطأ في الاتصال: $e",
        "employees": [],
      };
    }
  }
}