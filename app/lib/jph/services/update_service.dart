import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Same API the original screens call. The app is distributed from GitHub (web is always current);
/// there is no in-app self-update channel on the free plan, so no update is ever reported.
class UpdateService {
  static Future<Map<String, dynamic>> checkForUpdate() async =>
      {'success': true, 'update_available': false, 'maintenance': false};

  static Future<void> downloadAndInstallWithProgress(String url, BuildContext context, Map<String, dynamic> info) async {
    if (url.isEmpty) return;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

class UpdateDialog {
  static void show({
    required BuildContext context,
    required Map<String, dynamic> updateInfo,
    required VoidCallback onUpdate,
    VoidCallback? onLater,
    bool forceUpdate = false,
  }) {}

  static void showMaintenanceDialog({required BuildContext context, required String message}) {}
}
