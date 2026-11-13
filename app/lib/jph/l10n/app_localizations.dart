import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

class AppLocalizations {
  final Locale locale;

  AppLocalizations(this.locale);

  static String of(BuildContext context, String key) {
    return get(context, key);
  }

  static AppLocalizations? instance(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate = AppLocalizationsDelegate();

  Map<String, String>? _localizedStrings;

  Future<void> load() async {
    try {
      print('🌍 تحميل ترجمة للغة: ${locale.languageCode}');

      // تحميل من ملف JSON
      String jsonString = await rootBundle.loadString(
        'assets/jph_l10n/${locale.languageCode}.json',
      );

      Map<String, dynamic> jsonMap = json.decode(jsonString);

      _localizedStrings = {};
      jsonMap.forEach((key, value) {
        _localizedStrings![key] = value.toString();
      });

      print('✅ تم تحميل ${_localizedStrings!.length} كلمة للغة ${locale.languageCode}');
    } catch (e) {
      print('❌ خطأ في تحميل الترجمة: $e');
      _localizedStrings = _getDefaultTranslations();
    }
  }

  Map<String, String> _getDefaultTranslations() {
    switch (locale.languageCode) {
      case 'ar':
        return {
          'app_name': 'فاليو نيفو',
          'welcome': 'مرحباً',
          'loading': 'جاري التحميل...',
          'login': 'تسجيل الدخول',
          'logout': 'تسجيل الخروج',
          'dashboard': 'لوحة التحكم',
          'settings': 'الإعدادات',
          'language': 'اللغة',
          'dark_mode': 'الوضع المظلم',
          'enter_credentials': 'الرجاء إدخال بيانات الاعتماد',
          'login_failed': 'فشل تسجيل الدخول',
          'network_error': 'خطأ في الشبكة',
          'login_now': 'سجل الدخول الآن',
          'employee_id': 'رقم الموظف',
          'password': 'كلمة المرور',
          'logging_in': 'جاري تسجيل الدخول...',
          'required': 'مطلوب',
        };

      case 'hi':
        return {
          'app_name': 'जेपीएच उपस्थिति और प्रस्थान',
          'welcome': 'स्वागत है',
          'loading': 'लोड हो रहा है...',
          'login': 'लॉग इन',
          'logout': 'लॉग आउट',
          'dashboard': 'डैशबोर्ड',
          'settings': 'सेटिंग्स',
          'language': 'भाषा',
          'dark_mode': 'डार्क मोड',
          'enter_credentials': 'कृपया क्रेडेंशियल दर्ज करें',
          'login_failed': 'लॉगिन विफल',
          'network_error': 'नेटवर्क त्रुटि',
          'login_now': 'अब लॉगिन करें',
          'employee_id': 'कर्मचारी आईडी',
          'password': 'पासवर्ड',
          'logging_in': 'लॉग इन हो रहा है...',
          'required': 'आवश्यक',
        };

      case 'ur':
        return {
          'app_name': 'جے پی ایچ حاضری و روانگی',
          'welcome': 'خوش آمدید',
          'loading': 'لوڈ ہو رہا ہے...',
          'login': 'لاگ ان',
          'logout': 'لاگ آؤٹ',
          'dashboard': 'ڈیش بورڈ',
          'settings': 'ترتیبات',
          'language': 'زبان',
          'dark_mode': 'ڈارک موڈ',
          'enter_credentials': 'براہ کرم کریڈنشلز درج کریں',
          'login_failed': 'لاگ ان ناکام',
          'network_error': 'نیٹ ورک خرابی',
          'login_now': 'ابھی لاگ ان کریں',
          'employee_id': 'ملازم آئی ڈي',
          'password': 'پاس ورڈ',
          'logging_in': 'لاگ ان ہو رہا ہے...',
          'required': 'درکار',
        };

      default: // الإنجليزية (en)
        return {
          'app_name': 'VALUNIVO',
          'welcome': 'Welcome',
          'loading': 'Loading...',
          'login': 'Login',
          'logout': 'Logout',
          'dashboard': 'Dashboard',
          'settings': 'Settings',
          'language': 'Language',
          'dark_mode': 'Dark Mode',
          'enter_credentials': 'Please enter credentials',
          'login_failed': 'Login failed',
          'network_error': 'Network error',
          'login_now': 'Login now',
          'employee_id': 'Employee ID',
          'password': 'Password',
          'logging_in': 'Logging in...',
          'required': 'required',
        };
    }
  }

  String translate(String key) {
    return _localizedStrings?[key] ?? '[$key]';
  }

  static String get(BuildContext context, String key) {
    final localizations = instance(context);
    if (localizations == null) {
      print('⚠️ AppLocalizations غير متوفرة في context');
      return key;
    }
    return localizations.translate(key);
  }

  // 🔥 دالة خاصة للحصول على اسم اللغة الأصلي (بدون ترجمة)
  static String getLanguageNativeName(String languageCode) {
    switch (languageCode) {
      case 'ar':
        return 'العربية';
      case 'en':
        return 'English';
      case 'ur':
        return 'اردو';
      case 'hi':
        return 'हिन्दी';
      default:
        return languageCode.toUpperCase();
    }
  }

  // 🔥 دالة للحصول على الوصف بلغة الواجهة الحالية (مترجم)
  static String getLanguageTranslatedName(BuildContext context, String languageCode) {
    switch (languageCode) {
      case 'ar':
        return get(context, 'arabic') ?? 'Arabic';
      case 'en':
        return get(context, 'english') ?? 'English';
      case 'ur':
        return 'Urdu'; // يمكنك إضافته في ملفات الترجمة إذا أردت
      case 'hi':
        return 'Hindi'; // يمكنك إضافته في ملفات الترجمة إذا أردت
      default:
        return languageCode.toUpperCase();
    }
  }
}

class AppLocalizationsDelegate extends LocalizationsDelegate<AppLocalizations> {
  const AppLocalizationsDelegate();

  @override
  bool isSupported(Locale locale) {
    return ['ar', 'en', 'hi', 'ur'].contains(locale.languageCode);
  }

  @override
  Future<AppLocalizations> load(Locale locale) async {
    final localizations = AppLocalizations(locale);
    await localizations.load();
    return localizations;
  }

  @override
  bool shouldReload(AppLocalizationsDelegate old) => false;
}