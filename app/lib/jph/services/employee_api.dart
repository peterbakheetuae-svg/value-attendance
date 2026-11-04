// services/employee_api.dart
import 'api_service.dart';

class EmployeeApi {
  // جلب جميع الموظفين النشطين (على رأس العمل)
  static Future<Map<String, dynamic>> getActiveEmployees() async {
    print('📤 جلب الموظفين النشطين');

    return ApiService.post({
      "action": "getActiveEmployees",
    });
  }
}
