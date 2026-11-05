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
    // ringing alerts over the lock screen (permission / visit requests, overdue return)
    'android.permission.USE_FULL_SCREEN_INTENT',
    'android.permission.VIBRATE',
    // automatic update: the new APK is downloaded and handed to the Android installer
    'android.permission.REQUEST_INSTALL_PACKAGES',
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
  // the ringing alert opens the app over the lock screen
  if (!xml.contains('android:showWhenLocked')) {
    xml = xml.replaceFirst('android:name=".MainActivity"', 'android:name=".MainActivity"\n            android:showWhenLocked="true"\n            android:turnScreenOn="true"');
  }
  // automatic update (ota_update): file provider for the downloaded APK + install result receiver
  if (!xml.contains('OtaUpdateFileProvider')) {
    xml = xml.replaceFirst('</application>', '''
        <provider
            android:name="sk.fourq.otaupdate.OtaUpdateFileProvider"
            android:authorities="\${applicationId}.ota_update_provider"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data android:name="android.support.FILE_PROVIDER_PATHS" android:resource="@xml/ota_filepaths"/>
        </provider>
        <receiver android:name="sk.fourq.otaupdate.InstallResultReceiver" android:exported="false">
            <intent-filter><action android:name="\${applicationId}.ACTION_INSTALL_COMPLETE"/></intent-filter>
        </receiver>
    </application>''');
  }
  Directory('android/app/src/main/res/xml').createSync(recursive: true);
  File('android/app/src/main/res/xml/ota_filepaths.xml').writeAsStringSync('<?xml version="1.0" encoding="utf-8"?>\n'
      '<paths xmlns:android="http://schemas.android.com/apk/res/android">\n'
      '    <files-path name="internal_apk_storage" path="ota_update/"/>\n'
      '</paths>\n');
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
    // one fixed release key (android/key.properties, written by CI from the repository secret) so every
    // update installs over the previous app; without it the build stays debug-signed as before
    if (kts && !t.contains('key.properties')) {
      t = 'import java.util.Properties\n' + t;
      t = t.replaceFirst(RegExp(r'^android\s*\{', multiLine: true),
          'val keyProps = Properties().apply { val kf = rootProject.file("key.properties"); if (kf.exists()) kf.inputStream().use { load(it) } }\n\n'
          'android {\n'
          '    signingConfigs {\n'
          '        create("release") {\n'
          '            if (keyProps.isNotEmpty()) {\n'
          '                storeFile = file(keyProps.getProperty("storeFile"))\n'
          '                storePassword = keyProps.getProperty("storePassword")\n'
          '                keyAlias = keyProps.getProperty("keyAlias")\n'
          '                keyPassword = keyProps.getProperty("keyPassword")\n'
          '                storeType = "pkcs12"\n'
          '            }\n'
          '        }\n'
          '    }');
      t = t.replaceFirst('signingConfig = signingConfigs.getByName("debug")',
          'signingConfig = if (keyProps.isNotEmpty()) signingConfigs.getByName("release") else signingConfigs.getByName("debug")');
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

  // no white launch screen: the native splash uses the app's dark background
  for (final path in ['android/app/src/main/res/drawable/launch_background.xml', 'android/app/src/main/res/drawable-v21/launch_background.xml']) {
    final f = File(path);
    if (f.existsSync()) {
      f.writeAsStringSync('<?xml version="1.0" encoding="utf-8"?>\n'
          '<layer-list xmlns:android="http://schemas.android.com/apk/res/android">\n'
          '    <item><shape android:shape="rectangle"><solid android:color="#FF0B1020"/></shape></item>\n'
          '</layer-list>\n');
    }
  }
  for (final path in ['android/app/src/main/res/values/styles.xml', 'android/app/src/main/res/values-night/styles.xml']) {
    final f = File(path);
    if (f.existsSync()) {
      f.writeAsStringSync(f.readAsStringSync().replaceAll('?android:colorBackground', '@android:color/black'));
    }
  }

  final web = File('web/index.html');
  if (web.existsSync()) {
    var h = web.readAsStringSync();
    if (!h.contains('background:#0B1020')) h = h.replaceFirst('</head>', '<style>html,body{background:#0B1020;}</style>\n</head>');
    h = h.replaceFirst(RegExp(r'<title>[^<]*</title>'), '<title>Value Attendance</title>');
    if (!h.contains('dir="rtl"')) h = h.replaceFirst('<html>', '<html lang="ar" dir="rtl">');
    web.writeAsStringSync(h);
    stdout.writeln('web/index.html patched: title, lang, dir.');
  }
}
