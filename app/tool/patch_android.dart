// Run once after `flutter create --platforms=android,web .`:
//   dart run tool/patch_android.dart
// Adds the Android permissions the app needs and the app label. Idempotent.
import 'dart:io';

void main() {
  final f = File('android/app/src/main/AndroidManifest.xml');
  if (!f.existsSync()) {
    stderr.writeln('android/ not found — run: flutter create --platforms=android,web --org com.jph.realestatehr .');
    exit(1);
  }
  var xml = f.readAsStringSync();
  const perms = [
    'android.permission.INTERNET',
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
    'android.permission.CAMERA',
    // in-shift location follow-up (foreground service with a visible notification)
    'android.permission.FOREGROUND_SERVICE',
    'android.permission.FOREGROUND_SERVICE_LOCATION',
    'android.permission.POST_NOTIFICATIONS',
    'android.permission.WAKE_LOCK',
  ];
  for (final p in perms) {
    if (!xml.contains('"$p"')) {
      xml = xml.replaceFirst('<application', '<uses-permission android:name="$p"/>\n    <application');
    }
  }
  // Local/LAN development API is plain http; production must use https.
  if (!xml.contains('usesCleartextTraffic')) {
    xml = xml.replaceFirst('<application', '<application\n        android:usesCleartextTraffic="true"');
  }
  xml = xml.replaceFirst(RegExp(r'android:label="[^"]*"'), 'android:label="Value Attendance"');
  f.writeAsStringSync(xml);
  stdout.writeln('AndroidManifest.xml patched: ${perms.length} permissions, label, cleartext (dev).');

  // flutter_local_notifications needs core library desugaring
  for (final path in ['android/app/build.gradle.kts', 'android/app/build.gradle']) {
    final g = File(path);
    if (!g.existsSync()) continue;
    var t = g.readAsStringSync();
    final kts = path.endsWith('.kts');
    if (!t.contains('CoreLibraryDesugaringEnabled')) {
      t = t.replaceFirst(RegExp(r'compileOptions\s*\{'),
          kts ? 'compileOptions {\n        isCoreLibraryDesugaringEnabled = true' : 'compileOptions {\n        coreLibraryDesugaringEnabled true');
    }
    if (!t.contains('desugar_jdk_libs')) {
      final dep = kts ? 'coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")' : "coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'";
      if (RegExp(r'^dependencies\s*\{', multiLine: true).hasMatch(t)) {
        t = t.replaceFirst(RegExp(r'^dependencies\s*\{', multiLine: true), 'dependencies {\n    $dep');
      } else {
        t += '\ndependencies {\n    $dep\n}\n';
      }
    }
    // app id registered in Firebase (push notifications)
    t = t.replaceFirst(RegExp(r'applicationId\s*=?\s*"[^"]*"'), kts ? 'applicationId = "com.jph.valueattendance"' : 'applicationId "com.jph.valueattendance"');
    g.writeAsStringSync(t);
    stdout.writeln('$path patched: core library desugaring, applicationId.');
  }

  // sound used by system notifications (RawResourceAndroidNotificationSound('notification'))
  final snd = File('assets/sounds/notification.WAV');
  if (snd.existsSync()) {
    Directory('android/app/src/main/res/raw').createSync(recursive: true);
    snd.copySync('android/app/src/main/res/raw/notification.wav');
    stdout.writeln('notification sound copied to res/raw.');
  }

  // launcher icon + web icons = the original JPH app logo (tool/icons, made from assets/images/logo.png)
  for (final d in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']) {
    final f = File('tool/icons/android/$d.png');
    final dir = Directory('android/app/src/main/res/mipmap-$d');
    if (f.existsSync() && dir.existsSync()) f.copySync('${dir.path}/ic_launcher.png');
  }
  final adaptive = File('android/app/src/main/res/mipmap-anydpi-v26/ic_launcher.xml');
  if (adaptive.existsSync()) adaptive.deleteSync();
  for (final n in ['Icon-192', 'Icon-512', 'Icon-maskable-192', 'Icon-maskable-512']) {
    final f = File('tool/icons/web/$n.png');
    if (f.existsSync() && Directory('web/icons').existsSync()) f.copySync('web/icons/$n.png');
  }
  if (File('tool/icons/web/favicon.png').existsSync() && Directory('web').existsSync()) {
    File('tool/icons/web/favicon.png').copySync('web/favicon.png');
  }
  final wm = File('web/manifest.json');
  if (wm.existsSync()) {
    wm.writeAsStringSync(wm.readAsStringSync()
        .replaceAll(RegExp(r'"name":\s*"[^"]*"'), '"name": "Value Attendance"')
        .replaceAll(RegExp(r'"short_name":\s*"[^"]*"'), '"short_name": "Value Attendance"'));
  }
  stdout.writeln('launcher + web icons set to the app logo.');

  final web = File('web/index.html');
  if (web.existsSync()) {
    var h = web.readAsStringSync();
    h = h.replaceFirst(RegExp(r'<title>[^<]*</title>'), '<title>Value Attendance</title>');
    if (!h.contains('dir="rtl"')) h = h.replaceFirst('<html>', '<html lang="ar" dir="rtl">');
    web.writeAsStringSync(h);
    stdout.writeln('web/index.html patched: title, lang, dir.');
  }
}
