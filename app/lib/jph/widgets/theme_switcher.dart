import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../l10n/app_localizations.dart';

class ThemeSwitcher extends StatelessWidget {
  final bool showLabel;

  const ThemeSwitcher({
    super.key,
    this.showLabel = true,
  });

  @override
  Widget build(BuildContext context) {
    final controller = Provider.of<AppController>(context);

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => controller.toggleTheme(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // الأيقونة
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  child: controller.isDark
                      ? Icon(
                    Icons.dark_mode,
                    key: const ValueKey('dark'),
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurface,
                  )
                      : Icon(
                    Icons.light_mode,
                    key: const ValueKey('light'),
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),

                if (showLabel) ...[
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(context, 'dark_mode'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],

                const SizedBox(width: 4),
                Switch(
                  value: controller.isDark,
                  onChanged: (value) {
                    controller.toggleTheme();
                  },
                  activeColor: Theme.of(context).colorScheme.primary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}