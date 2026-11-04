import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class SessionService {
  static Future<void> save(Map user) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool("logged", true);
    await p.setString("uid", user["uid"].toString());
    await p.setString("name", user["name"].toString());
    await p.setString("role", user["role"].toString());
    await p.setString("photo", (user["photo"] ?? "").toString());
    await p.setString("validity", (user["validity"] ?? "").toString());
    await p.setString("companyId", (user["companyId"] ?? "").toString());

    // Multi-company context (Phase 11 / T11.1)
    await p.setString("home_company_id", (user["homeCompanyId"] ?? "").toString());
    await p.setBool("platform_owner", user["platformOwner"] == true);
    await p.setString("company_name", (user["companyName"] ?? "").toString());
    await p.setString("company_currency", (user["companyCurrency"] ?? "").toString());

    // Persist the available companies list as JSON.
    final companies = user["companies"];
    if (companies is List) {
      await p.setString("available_companies", jsonEncode(companies));
    } else {
      await p.setString("available_companies", "[]");
    }

    // Persist the last selected company context (may be empty = home company).
    await p.setString(
        "current_company_id", (user["currentCompanyId"] ?? "").toString());
  }

  /// Updates only the current company context without rewriting the full session.
  static Future<void> setCurrentCompanyId(String? companyId) async {
    final p = await SharedPreferences.getInstance();
    await p.setString("current_company_id", companyId ?? "");
  }

  static Future<Map<String, dynamic>?> get() async {
    final p = await SharedPreferences.getInstance();
    if (p.getBool("logged") != true) return null;

    // Decode the available companies list from JSON.
    List<Map<String, dynamic>> companies = const [];
    try {
      final raw = p.getString("available_companies") ?? "[]";
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        companies = decoded
            .whereType<Map>()
            .map((m) => m.cast<String, dynamic>())
            .toList(growable: false);
      }
    } catch (_) {
      companies = const [];
    }

    return {
      "uid": p.getString("uid") ?? "",
      "name": p.getString("name") ?? "",
      "role": p.getString("role") ?? "",
      "photo": p.getString("photo") ?? "",
      "validity": p.getString("validity") ?? "",
      "companyId": p.getString("companyId") ?? "",
      // Multi-company fields
      "homeCompanyId": p.getString("home_company_id") ?? "",
      "platformOwner": p.getBool("platform_owner") ?? false,
      "companyName": p.getString("company_name") ?? "",
      "companyCurrency": p.getString("company_currency") ?? "",
      "companies": companies,
      "currentCompanyId": p.getString("current_company_id") ?? "",
    };
  }

  static Future<void> logout() async {
    final p = await SharedPreferences.getInstance();
    // keep the device id (phone binding) and the app look across sign-outs
    final keep = {for (final k in ['device_id', 'language_code', 'theme_mode', 'is_dark']) k: p.get(k)};
    await p.clear();
    for (final e in keep.entries) {
      final v = e.value;
      if (v is String) await p.setString(e.key, v);
      if (v is bool) await p.setBool(e.key, v);
      if (v is int) await p.setInt(e.key, v);
    }
  }
}
