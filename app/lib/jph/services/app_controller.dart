import 'dart:math' as math;
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:ui';

class AppController extends ChangeNotifier {
  ThemeMode _themeMode = ThemeMode.light;
  Locale _locale = const Locale('ar');
  bool _isRTL = true;
  bool _isInitialized = false;

  String? _userPhoto;
  String? _userUid;
  String? _userValidity;      // ✅ جديد
  String? _userCompanyId;     // ✅ جديد (company code, legacy)

  // Multi-company state (Phase 11 / T11.1)
  String? _homeCompanyId;          // UUID of the employing company
  String? _currentCompanyId;       // UUID of the selected company context
  String? _companyName;
  String? _companyCurrency;
  bool _isPlatformOwner = false;
  List<Map<String, dynamic>> _availableCompanies = const [];

  bool _hasUnreadNotifications = false;
  bool _hasNotifications = false;

  // Getters
  ThemeMode get themeMode => _themeMode;
  Locale get locale => _locale;
  bool get isDark => _themeMode == ThemeMode.dark;
  bool get isRTL => _isRTL;
  String get languageCode => _locale.languageCode;
  String? get userPhoto => _userPhoto;
  String? get userUid => _userUid;
  String? get userValidity => _userValidity;       // ✅
  String? get userCompanyId => _userCompanyId;     // ✅

  // Multi-company getters
  String? get homeCompanyId => _homeCompanyId;
  String? get currentCompanyId => _currentCompanyId ?? _homeCompanyId;
  String? get companyName => _companyName;
  String? get companyCurrency => _companyCurrency;
  bool get isPlatformOwner => _isPlatformOwner;
  List<Map<String, dynamic>> get availableCompanies => _availableCompanies;

  /// True when the user has memberships on more than one company.
  bool get hasMultipleCompanies => _availableCompanies.length > 1;

  bool get hasUnreadNotifications => _hasUnreadNotifications;
  bool get hasNotifications => _hasNotifications;

  AppController() {
    _initWithDefaults();
  }

  void _initWithDefaults() {
    print('🎯 تهيئة AppController بقيم افتراضية');
    _locale = const Locale('ar');
    _isRTL = true;
    _themeMode = ThemeMode.dark;
    _userPhoto = null;
    _userUid = null;
    _userValidity = null;
    _userCompanyId = null;
    _homeCompanyId = null;
    _currentCompanyId = null;
    _companyName = null;
    _companyCurrency = null;
    _isPlatformOwner = false;
    _availableCompanies = const [];
    notifyListeners();
  }

  Future<void> initialize() async {
    if (!_isInitialized) {
      await _init();
    }
  }

  Future<void> _init() async {
    if (_isInitialized) return;
    await _loadPreferences();
    await _loadNotificationStatus();
    _isInitialized = true;
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();

      // اللغة
      final languageCode = prefs.getString('language_code') ?? 'ar';
      _locale = Locale(languageCode);
      _isRTL = languageCode == 'ar';

      // الثيم
      final themeIndex = prefs.getInt('theme_mode') ?? 1;
      if (themeIndex == 0) {
        final brightness = window.platformBrightness;
        _themeMode = brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light;
        await prefs.setInt('theme_mode', _themeMode == ThemeMode.dark ? 2 : 1);
      } else {
        _themeMode = themeIndex == 2 ? ThemeMode.dark : ThemeMode.light;
      }

      _userPhoto = prefs.getString('user_photo');
      _userUid = prefs.getString('user_uid');
      _userValidity = prefs.getString('user_validity');       // ✅ تحميل
      _userCompanyId = prefs.getString('user_company_id');    // ✅ تحميل

      // Multi-company state
      _homeCompanyId = prefs.getString('home_company_id');
      final currentRaw = prefs.getString('current_company_id');
      _currentCompanyId = (currentRaw != null && currentRaw.isNotEmpty) ? currentRaw : null;
      _companyName = prefs.getString('company_name');
      _companyCurrency = prefs.getString('company_currency');
      _isPlatformOwner = prefs.getBool('platform_owner') ?? false;

      // Decode available companies from JSON
      try {
        final raw = prefs.getString('available_companies');
        if (raw != null && raw.isNotEmpty) {
          final decoded = jsonDecode(raw);
          if (decoded is List) {
            _availableCompanies = decoded
                .whereType<Map>()
                .map((m) => m.cast<String, dynamic>())
                .toList(growable: false);
          }
        }
      } catch (e) {
        _availableCompanies = const [];
      }

      print('📱 AppController: اللغة=$languageCode, الثيم=$_themeMode');
      print('🆔 المستخدم الحالي: ${_userUid ?? "غير مسجل"}');
      print('🔰 الصلاحية: $_userValidity');
      print('🏢 الشركة: $_userCompanyId');
      print('🏢 الشركة الرئيسية: $_homeCompanyId');
      print('🏢 الشركة الحالية: $currentCompanyId');
      print('🏢 عدد الشركات المتاحة: ${_availableCompanies.length}');

      notifyListeners();
    } catch (e) {
      print('❌ خطأ في تحميل التفضيلات: $e');
    }
  }

  // ✅ حفظ معرف المستخدم
  Future<void> setUserUid(String uid) async {
    try {
      _userUid = uid;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_uid', uid);
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في حفظ معرف المستخدم: $e');
    }
  }

  // ✅ حفظ الصلاحية
  Future<void> setUserValidity(String validity) async {
    try {
      _userValidity = validity;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_validity', validity);
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في حفظ الصلاحية: $e');
    }
  }

  // ✅ حفظ معرف الشركة
  Future<void> setUserCompanyId(String companyId) async {
    try {
      _userCompanyId = companyId;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_company_id', companyId);
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في حفظ معرف الشركة: $e');
    }
  }

  // ✅ دالة شاملة لحفظ جميع بيانات المستخدم بعد تسجيل الدخول
  Future<void> saveUserData({
    required String uid,
    required String name,
    required String role,
    String? photo,
    String? validity,
    String? companyId,
    // Multi-company fields (Phase 11 / T11.1)
    String? homeCompanyId,
    String? companyName,
    String? companyCurrency,
    bool platformOwner = false,
    List<Map<String, dynamic>>? companies,
    String? currentCompanyId,
  }) async {
    try {
      _userUid = uid;
      _userValidity = validity;
      _userCompanyId = companyId;
      if (photo != null) _userPhoto = photo;

      // Multi-company state
      _homeCompanyId = homeCompanyId;
      _companyName = companyName;
      _companyCurrency = companyCurrency;
      _isPlatformOwner = platformOwner;
      _availableCompanies = companies ?? const [];
      _currentCompanyId = (currentCompanyId != null && currentCompanyId.isNotEmpty)
          ? currentCompanyId
          : null;

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_uid', uid);
      await prefs.setString('user_name', name);
      await prefs.setString('user_role', role);
      if (photo != null) await prefs.setString('user_photo', photo);
      if (validity != null) await prefs.setString('user_validity', validity);
      if (companyId != null) await prefs.setString('user_company_id', companyId);

      // Persist multi-company state
      if (homeCompanyId != null) await prefs.setString('home_company_id', homeCompanyId);
      if (companyName != null) await prefs.setString('company_name', companyName);
      if (companyCurrency != null) await prefs.setString('company_currency', companyCurrency);
      await prefs.setBool('platform_owner', platformOwner);
      if (companies != null) {
        await prefs.setString('available_companies', jsonEncode(companies));
      }
      await prefs.setString('current_company_id', currentCompanyId ?? '');

      print('✅ تم حفظ جميع بيانات المستخدم');
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في حفظ بيانات المستخدم: $e');
    }
  }

  // ✅ تسجيل الخروج
  Future<void> clearUserData() async {
    try {
      _userUid = null;
      _userValidity = null;
      _userCompanyId = null;
      _userPhoto = null;
      // Multi-company state
      _homeCompanyId = null;
      _currentCompanyId = null;
      _companyName = null;
      _companyCurrency = null;
      _isPlatformOwner = false;
      _availableCompanies = const [];
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('user_uid');
      await prefs.remove('user_name');
      await prefs.remove('user_role');
      await prefs.remove('user_photo');
      await prefs.remove('user_validity');
      await prefs.remove('user_company_id');
      await prefs.remove('home_company_id');
      await prefs.remove('current_company_id');
      await prefs.remove('company_name');
      await prefs.remove('company_currency');
      await prefs.remove('platform_owner');
      await prefs.remove('available_companies');
      print('🗑️ تم مسح بيانات المستخدم');
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في مسح بيانات المستخدم: $e');
    }
  }

  // ✅ حفظ الصورة

  /// Switches the active company context. The [companyId] must be one of the
  /// entries in [availableCompanies]. Pass null to reset to home company.
  /// The backend re-checks authorisation on every request.
  Future<void> switchCompany(String? companyId) async {
    if (companyId == null) {
      _currentCompanyId = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('current_company_id', '');
      notifyListeners();
      return;
    }

    // Only allow switching to a company the user is a member of.
    Map<String, dynamic>? match;
    for (final c in _availableCompanies) {
      if (c['id'] == companyId) {
        match = c;
        break;
      }
    }
    if (match == null) {
      print('⚠️ switchCompany: companyId $companyId not in available companies');
      return;
    }

    _currentCompanyId = companyId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('current_company_id', companyId);
    print('🔄 تم تبديل الشركة إلى: ${match['name']} ($companyId)');
    notifyListeners();
  }

  Future<void> saveUserPhoto(String photoUrl) async {
    try {
      _userPhoto = photoUrl;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('user_photo', photoUrl);
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في حفظ الصورة: $e');
    }
  }

  // ✅ حذف الصورة
  Future<void> clearUserPhoto() async {
    try {
      _userPhoto = null;
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('user_photo');
      notifyListeners();
    } catch (e) {
      print('❌ خطأ في حذف الصورة: $e');
    }
  }

  // دوال الإشعارات (كما هي)
  void updateNotificationStatus(bool hasUnread, bool hasAny) {
    if (_hasUnreadNotifications == hasUnread && _hasNotifications == hasAny) return;
    _hasUnreadNotifications = hasUnread;
    _hasNotifications = hasAny;
    _saveNotificationStatus();
    notifyListeners();
  }

  Future<void> _saveNotificationStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('has_unread_notifications', _hasUnreadNotifications);
      await prefs.setBool('has_notifications', _hasNotifications);
    } catch (e) {
      print('❌ خطأ في حفظ حالة الإشعارات: $e');
    }
  }

  Future<void> _loadNotificationStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _hasUnreadNotifications = prefs.getBool('has_unread_notifications') ?? false;
      _hasNotifications = prefs.getBool('has_notifications') ?? false;
    } catch (e) {
      print('❌ خطأ في تحميل حالة الإشعارات: $e');
    }
  }

  // دوال اللغة والثيم
  Future<void> setLanguage(String languageCode) async {
    if (_locale.languageCode == languageCode) return;
    _locale = Locale(languageCode);
    _isRTL = languageCode == 'ar';
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('language_code', languageCode);
    } catch (e) {
      print('❌ خطأ في حفظ اللغة: $e');
    }
    notifyListeners();
  }

  Future<void> toggleLanguage() async {
    final newLang = _locale.languageCode == 'ar' ? 'en' : 'ar';
    await setLanguage(newLang);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (mode == ThemeMode.system) mode = ThemeMode.light;
    if (_themeMode == mode) return;
    _themeMode = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('theme_mode', mode == ThemeMode.dark ? 2 : 1);
    } catch (e) {
      print('❌ خطأ في حفظ الثيم: $e');
    }
    notifyListeners();
  }

  Future<void> setThemeByName(String themeName) async {
    await setThemeMode(themeName == 'dark' ? ThemeMode.dark : ThemeMode.light);
  }

  Future<void> toggleTheme() async {
    await setThemeMode(_themeMode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark);
  }

  String get themeName => isDark ? 'dark' : 'light';
  List<String> get availableThemes => ['light', 'dark'];
}