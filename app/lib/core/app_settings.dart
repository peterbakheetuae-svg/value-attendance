import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'i18n.dart';

/// Theme mode + language, persisted on the device.
class AppSettings extends ChangeNotifier {
  ThemeMode _mode = ThemeMode.light;
  String _lang = 'ar';

  ThemeMode get themeMode => _mode;
  String get lang => _lang;
  bool get isRtl => _lang == 'ar';
  Locale get locale => Locale(_lang);

  Future<void> restore() async {
    try {
      final p = await SharedPreferences.getInstance();
      _mode = p.getString('theme') == 'dark' ? ThemeMode.dark : ThemeMode.light;
      _lang = p.getString('lang') == 'en' ? 'en' : 'ar';
    } catch (_) {/* first run / storage unavailable: defaults */}
    I18n.lang = _lang;
  }

  Future<void> setTheme(ThemeMode m) async {
    _mode = m;
    notifyListeners();
    try { (await SharedPreferences.getInstance()).setString('theme', m == ThemeMode.dark ? 'dark' : 'light'); } catch (_) {}
  }

  Future<void> setLang(String l) async {
    _lang = l == 'en' ? 'en' : 'ar';
    I18n.lang = _lang;
    notifyListeners();
    try { (await SharedPreferences.getInstance()).setString('lang', _lang); } catch (_) {}
  }
}
