import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../l10n/app_localizations.dart';

class LanguageSwitcher extends StatelessWidget {
  final bool showLabel;

  const LanguageSwitcher({
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
          onTap: () => controller.toggleLanguage(),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // الأيقونة
                Icon(
                  Icons.language,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurface,
                ),

                if (showLabel) ...[
                  const SizedBox(width: 8),
                  Text(
                    controller.languageCode == 'ar' ? 'العربية' : 'English',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ],

                const SizedBox(width: 4),
                Icon(
                  Icons.swap_horiz,
                  size: 20,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}