import 'package:flutter/foundation.dart';

/// Where the app is running. Kept in one place so every Windows-only adaptation reads the same answer.
class PlatformInfo {
  PlatformInfo._();

  /// The native Windows desktop app (VALUNIVO.exe).
  static bool get isWindows => !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  /// A computer screen: the website, or the Windows app. Both use the website's computer layout
  /// (glass side bar + page) — the Windows app shows exactly what the site shows on a PC.
  static bool get isComputer => kIsWeb || isWindows;
}
