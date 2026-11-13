import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import 'fingerprint_config_team.dart';
import '../../services/dashboard_state.dart';
import 'dash_mode_team.dart';
import '../../widgets/glass_ui.dart';

Future<void> showBreakAlertDialog({
  required BuildContext context,
  required DashboardState state,
  required ValueNotifier<String> liveBreakTimeN,
  required bool isBreakExceeded,
  required Future<void> Function() stopSound,
  required Future<void> Function() executeEndBreak,
  required bool autoShow,
}) async {
  final appController = Provider.of<AppController>(context, listen: false);
  final isDark = appController.isDark;
  final breakStartTime = state.breakStartTime;
  String formattedTime = breakStartTime;
  try {
    final parts = breakStartTime.split(":");
    if (parts.length == 2) {
      final hour = int.parse(parts[0]);
      final minute = parts[1];
      final period = hour >= 12 ? "PM" : "AM";
      final hour12 = hour > 12 ? hour - 12 : hour == 0 ? 12 : hour;
      formattedTime = "$hour12:${minute.padLeft(2, "0")} $period";
    }
  } catch (_) {}

  await showDialog(
    context: context,
    barrierDismissible: !autoShow,
    builder: (BuildContext dialogContext) {
      return Directionality(
        textDirection: appController.isRTL ? TextDirection.rtl : TextDirection.ltr,
        child: Dialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24.0),
          ),
          backgroundColor: isDark
              ? Ar.grey.shade900.withOpacity(0.98)
              : Colors.white.withOpacity(0.98),
          insetPadding: const EdgeInsets.all(16),
          child: SingleChildScrollView(
            child: Container(
              padding: const EdgeInsets.all(24.0),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(dialogContext).size.height * 0.9,
              ),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(24.0),
                border: Border.all(
                  color: isDark
                      ? Colors.white.withOpacity(0.1)
                      : Colors.black.withOpacity(0.05),
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      Container(
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          color: isBreakExceeded
                              ? Ar.amber.withOpacity(0.1)
                              : AppColors.secondary.withOpacity(0.1),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: isBreakExceeded
                                ? Ar.amber.withOpacity(0.3)
                                : AppColors.secondary.withOpacity(0.3),
                            width: 3,
                          ),
                        ),
                        child: Icon(
                          Icons.coffee,
                          size: 50,
                          color: isBreakExceeded ? Ar.amber : AppColors.secondary,
                        ),
                      ),
                      if (isBreakExceeded)
                        Positioned(
                          right: 5,
                          top: 5,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: Ar.red,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: isDark ? Colors.black : Colors.white,
                                width: 3,
                              ),
                            ),
                            child: const Icon(
                              Icons.notifications,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  Text(
                    isBreakExceeded
                        ? AppLocalizations.of(dialogContext, 'breakExceededAlert')
                        : AppLocalizations.of(dialogContext, 'youAreOnBreak'),
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: isBreakExceeded ? Ar.amber : (isDark ? Colors.white : Colors.black),
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),

                  Text(
                    isBreakExceeded
                        ? AppLocalizations.of(dialogContext, 'breakExceededMessage')
                        : AppLocalizations.of(dialogContext, 'breakStarted'),
                    style: TextStyle(
                      fontSize: 16,
                      color: isDark ? Colors.white70 : Ar.grey.shade700,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 24),

                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                    decoration: BoxDecoration(
                      color: isBreakExceeded
                          ? Ar.amber.withOpacity(0.1)
                          : AppColors.secondary.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isBreakExceeded
                            ? Ar.amber.withOpacity(0.3)
                            : AppColors.secondary.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          AppLocalizations.of(dialogContext, 'breakStarted'),
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white70 : Ar.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          formattedTime,
                          style: TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: isBreakExceeded ? Ar.amber : AppColors.secondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  Container(
                    padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24),
                    decoration: BoxDecoration(
                      color: isBreakExceeded
                          ? Ar.amber.withOpacity(0.05)
                          : AppColors.secondary.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: isBreakExceeded
                            ? Ar.amber.withOpacity(0.2)
                            : AppColors.secondary.withOpacity(0.2),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          AppLocalizations.of(dialogContext, 'totalBreakTime'),
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white70 : Ar.grey.shade700,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          liveBreakTimeN.value,
                          style: TextStyle(
                            fontSize: 26,
                            fontWeight: FontWeight.bold,
                            color: isBreakExceeded ? Ar.amber : (isDark ? Colors.white : Colors.black),
                          ),
                        ),
                        if (isBreakExceeded) ...[
                          const SizedBox(height: 4),
                          Text(
                            AppLocalizations.of(dialogContext, 'breakLimitExceeded'),
                            style: TextStyle(
                              fontSize: 12,
                              color: Ar.amber,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 32),

                  AnimatedFingerprintAction(
                    config: FingerUiConfig(
                      title: AppLocalizations.of(dialogContext, 'endBreak'),
                      subtitle: "",
                      color: isBreakExceeded ? Ar.amber : AppColors.secondary,
                      iconBg: isBreakExceeded ? Ar.amber : AppColors.secondary,
                    ),
                    onSuccess: () async {
                      await stopSound();
                      Navigator.of(dialogContext).pop();
                      await executeEndBreak();
                    },
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}