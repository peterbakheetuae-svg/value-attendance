import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

class LanguagePicker extends StatelessWidget {
  final String current;
  final Function(String) onChange;

  const LanguagePicker({
    super.key,
    required this.current,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 🔥 اللغة العربية - تظهر "العربية" دائماً بدون ترجمة
        _LanguageOption(
          title: AppLocalizations.getLanguageNativeName('ar'), // العربية
          value: 'ar',
          current: current,
          onChange: onChange,
          flag: '🇸🇦',
          subtitle: AppLocalizations.getLanguageTranslatedName(context, 'ar'), // Arabic (مترجم)
        ),
        const SizedBox(height: 8),

        // 🔥 اللغة الإنجليزية - تظهر "English" دائماً بدون ترجمة
        _LanguageOption(
          title: AppLocalizations.getLanguageNativeName('en'), // English
          value: 'en',
          current: current,
          onChange: onChange,
          flag: '🇺🇸',
          subtitle: AppLocalizations.getLanguageTranslatedName(context, 'en'), // الإنجليزية (مترجم)
        ),
        const SizedBox(height: 8),

        // 🔥 اللغة الأردية - تظهر "اردو" دائماً بدون ترجمة
        _LanguageOption(
          title: AppLocalizations.getLanguageNativeName('ur'), // اردو
          value: 'ur',
          current: current,
          onChange: onChange,
          flag: '🇵🇰',
          subtitle: AppLocalizations.getLanguageTranslatedName(context, 'ur'), // Urdu (مترجم)
        ),
        const SizedBox(height: 8),

        // 🔥 اللغة الهندية - تظهر "हिन्दी" دائماً بدون ترجمة
        _LanguageOption(
          title: AppLocalizations.getLanguageNativeName('hi'), // हिन्दी
          value: 'hi',
          current: current,
          onChange: onChange,
          flag: '🇮🇳',
          subtitle: AppLocalizations.getLanguageTranslatedName(context, 'hi'), // Hindi (مترجم)
        ),
      ],
    );
  }
}

class _LanguageOption extends StatelessWidget {
  final String title;
  final String value;
  final String current;
  final Function(String) onChange;
  final String flag;
  final String subtitle;

  const _LanguageOption({
    required this.title,
    required this.value,
    required this.current,
    required this.onChange,
    required this.flag,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final isSelected = current == value;

    return Card(
      color: isSelected
          ? Theme.of(context).colorScheme.primary.withOpacity(0.1)
          : Theme.of(context).colorScheme.surfaceVariant,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: isSelected
              ? Theme.of(context).colorScheme.primary
              : Colors.transparent,
          width: 1.5,
        ),
      ),
      child: ListTile(
        leading: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Text(
              flag,
              style: const TextStyle(
                fontSize: 24,
              ),
            ),
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        subtitle: subtitle.isNotEmpty
            ? Text(
          subtitle,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontStyle: FontStyle.italic,
          ),
        )
            : null,
        trailing: isSelected
            ? Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        )
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        onTap: () => onChange(value),
      ),
    );
  }
}