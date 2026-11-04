import 'api_service.dart';

class EmployeesApi {
  /// جلب قائمة جميع الموظفين
  static Future<Map<String, dynamic>> getAllEmployees() {
    return ApiService.post({
      "action": "get_all_employees",
    });
  }

  /// جلب بيانات موظف محدد
  static Future<Map<String, dynamic>> getEmployeeDetails(String uid) {
    return ApiService.post({
      "action": "get_employee_details",
      "uid": uid,
    });
  }

  /// تحديث بيانات موظف
  static Future<Map<String, dynamic>> updateEmployee({
    required String uid,
    required Map<String, dynamic> data,
  }) {
    return ApiService.post({
      "action": "update_employee",
      "uid": uid,
      ...data,
    });
  }

  /// تحديث صورة الموظف
  static Future<Map<String, dynamic>> updateEmployeePhoto({
    required String uid,
    required String imageBase64,
  }) {
    return ApiService.post({
      "action": "update_employee_photo",
      "uid": uid,
      "image": imageBase64,
    });
  }

  /// تغيير حالة الموظف للدخول (Active - العمود E)
  static Future<Map<String, dynamic>> changeEmployeeStatus({
    required String uid,
    required bool active,
  }) {
    return ApiService.post({
      "action": "change_employee_status",
      "uid": uid,
      "active": active,
    });
  }

  /// تغيير وضع الموظف للحضور والانصراف (الوضع - العمود V)
  static Future<Map<String, dynamic>> changeEmployeeWorkStatus({
    required String uid,
    required String status,
  }) {
    return ApiService.post({
      "action": "change_employee_work_status",
      "uid": uid,
      "status": status,
    });
  }

  /// إضافة موظف جديد
  static Future<Map<String, dynamic>> addEmployee({
    required Map<String, dynamic> data,
  }) {
    return ApiService.post({
      "action": "add_employee",
      ...data,
    });
  }

  /// جلب الموظفين النشطين فقط
  static Future<Map<String, dynamic>> getActiveEmployees() {
    return ApiService.post({
      "action": "getActiveEmployees",
    });
  }
}