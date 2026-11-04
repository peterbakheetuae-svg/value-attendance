import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

class ThemePicker extends StatelessWidget {
  final ThemeMode current;
  final Function(ThemeMode) onChange;

  const ThemePicker({
    super.key,
    required this.current,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 🔥 الوضع التلقائي
        _ThemeOption(
          title: AppLocalizations.of(context, 'auto'),
          subtitle: AppLocalizations.of(context, 'auto_desc'),
          value: ThemeMode.system,
          current: current,
          onChange: onChange,
          icon: Icons.brightness_auto,
        ),
        const SizedBox(height: 8),

        // 🔥 الوضع الفاتح
        _ThemeOption(
          title: AppLocalizations.of(context, 'light'),
          subtitle: AppLocalizations.of(context, 'light_desc'),
          value: ThemeMode.light,
          current: current,
          onChange: onChange,
          icon: Icons.light_mode,
        ),
        const SizedBox(height: 8),

        // 🔥 الوضع المظلم
        _ThemeOption(
          title: AppLocalizations.of(context, 'dark'),
          subtitle: AppLocalizations.of(context, 'dark_desc'),
          value: ThemeMode.dark,
          current: current,
          onChange: onChange,
          icon: Icons.dark_mode,
        ),
      ],
    );
  }
}

class _ThemeOption extends StatelessWidget {
  final String title;
  final String subtitle;
  final ThemeMode value;
  final ThemeMode current;
  final Function(ThemeMode) onChange;
  final IconData icon;

  const _ThemeOption({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.current,
    required this.onChange,
    required this.icon,
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
            color: Theme.of(context).colorScheme.surface,
          ),
          child: Icon(
            icon,
            color: Theme.of(context).colorScheme.primary,
          ),
        ),
        title: Text(
          title,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(
            fontSize: 14,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: isSelected
            ? Icon(
          Icons.check_circle,
          color: Theme.of(context).colorScheme.primary,
        )
            : null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        onTap: () => onChange(value),
      ),
    );
  }
}