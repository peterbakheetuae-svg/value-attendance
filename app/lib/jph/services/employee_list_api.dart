import 'api_service.dart';

class EmployeeListApi {
  static Future<Map<String, dynamic>> fetch() async {
    try {
      final response = await ApiService.post({
        "action": "employee_list",
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