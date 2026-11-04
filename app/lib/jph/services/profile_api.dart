// lib/services/profile_api.dart
import 'api_service.dart';

class ProfileApi {
  /// Load profile data (Employees or Employers)
  static Future<Map<String, dynamic>> load(String uid) async {
    return ApiService.post({
      "action": "profile",
      "uid": uid,
    });
  }

  /// Update profile fields (email, phone, bank details, photo)
  static Future<Map<String, dynamic>> updateProfile({
    required String uid,
    String? email,
    String? phone,
    String? bankName,
    String? accountHolder,
    String? iban,
    String? accountNumber,
    String? photoBase64,
    required String currentUserUid, // UID of the user making the change
  }) async {
    final Map<String, dynamic> body = {
      "action": "update_profile",
      "uid": uid,
      "currentUserUid": currentUserUid,
    };
    if (email != null) body["email"] = email;
    if (phone != null) body["phone"] = phone;
    if (bankName != null) body["bankName"] = bankName;
    if (accountHolder != null) body["accountHolder"] = accountHolder;
    if (iban != null) body["iban"] = iban;
    if (accountNumber != null) body["accountNumber"] = accountNumber;
    if (photoBase64 != null) body["photo"] = photoBase64;

    return ApiService.post(body);
  }
}