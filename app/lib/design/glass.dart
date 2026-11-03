// JPH design system — glass surfaces.
// GlassCard, PageHeader, InfoTile, SettingTile, GlassDivider, GlassMiniCard and the
// background reproduce the original JPH Attendance widgets value-for-value
// (blur 14/18, radius 26, 1px white 30% border, 28/14 shadow, etc.). The only structural
// change is that they read light/dark from Theme instead of the old AppController.
import 'dart:ui';
import 'package:flutter/material.dart';
import 'app_colors.dart';

bool isDarkOf(BuildContext c) => Theme.of(c).brightness == Brightness.dark;

/* ===================== BACKGROUND (original AppBackground) ===================== */

class AppBackground extends StatelessWidget {
  final Widget child;
  final bool showOverlay;
  final bool safeArea;
  const AppBackground({super.key, required this.child, this.showOverlay = true, this.safeArea = true});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final img = isDark ? 'assets/bg/dark_bg.png' : 'assets/bg/light_bg.png';
    return RepaintBoundary(
      child: Stack(children: [
        Positioned.fill(
          child: Image.asset(img, fit: BoxFit.cover, filterQuality: FilterQuality.low, gaplessPlayback: true,
              errorBuilder: (_, __, ___) => _fallback(isDark)),
        ),
        if (showOverlay)
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [
                  (isDark ? Colors.black : Colors.white).withValues(alpha: isDark ? 0.35 : 0.08),
                  Colors.transparent,
                  (isDark ? Colors.black : Colors.white).withValues(alpha: isDark ? 0.55 : 0.10),
                ]),
              ),
              child: const SizedBox.expand(),
            ),
          ),
        Positioned.fill(child: safeArea ? SafeArea(child: child) : child),
      ]),
    );
  }

  Widget _fallback(bool isDark) => DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter, end: Alignment.bottomCenter,
            colors: isDark ? [Colors.black87, Colors.grey[900]!] : [Colors.blue[50]!, Colors.white],
          ),
        ),
      );
}

/* ===================== GLASS CARD ===================== */

class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final Color? backgroundColor;
  final bool showShadow;
  final VoidCallback? onTap;
  const GlassCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.radius = 26,
      this.backgroundColor, this.showShadow = true, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final borderColor = isDark ? AppColors.outlineDark.withValues(alpha: 0.3) : Colors.white.withValues(alpha: 0.30);
    final shadowColor = isDark ? Colors.black.withValues(alpha: 0.30) : Colors.black.withValues(alpha: 0.12);
    final blurSigma = isDark ? 18.0 : 14.0;
    Widget body = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor, width: 1.0),
        boxShadow: showShadow ? [BoxShadow(blurRadius: 28, offset: const Offset(0, 14), color: shadowColor)] : null,
      ),
      child: child,
    );
    if (onTap != null) {
      body = Material(type: MaterialType.transparency,
          child: InkWell(borderRadius: BorderRadius.circular(radius), onTap: onTap, child: body));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma), child: body),
    );
  }
}

/* ===================== PAGE HEADER ===================== */

class PageHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const PageHeader({super.key, required this.title, this.trailing});
  @override
  Widget build(BuildContext context) {
    final textColor = isDarkOf(context) ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(children: [
        Expanded(child: Text(title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: textColor))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/* ===================== SECTION TITLE (dashboard "today_time_log" style) ===================== */

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 10),
        child: Row(children: [
          Expanded(child: Text(text, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
          if (trailing != null) trailing!,
        ]),
      );
}

/* ===================== INFO TILE ===================== */

class InfoTile extends StatelessWidget {
  final String title;
  final String value;
  const InfoTile({super.key, required this.title, required this.value});
  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: TextStyle(color: isDark ? AppColors.onSurfaceVariantDark : Colors.black54)),
        const SizedBox(width: 12),
        Flexible(child: Text(value, textAlign: TextAlign.end,
            style: TextStyle(fontWeight: FontWeight.bold, color: isDark ? AppColors.onSurfaceDark : Colors.black))),
      ]),
    );
  }
}

/* ===================== SETTING TILE ===================== */

class SettingTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final bool showTrailing;
  final Color? iconColor;
  const SettingTile({super.key, required this.icon, required this.title, required this.onTap, this.subtitle,
      this.showTrailing = true, this.iconColor});
  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    return ListTile(
      leading: Icon(icon, color: iconColor ?? (isDark ? AppColors.primaryLight : AppColors.primary)),
      title: Text(title, style: TextStyle(color: isDark ? AppColors.onSurfaceDark : Colors.black)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(fontSize: 12,
          color: isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight)),
      trailing: showTrailing
          ? Icon(Directionality.of(context) == TextDirection.rtl ? Icons.chevron_left : Icons.chevron_right,
              color: isDark ? AppColors.onSurfaceVariantDark : Colors.grey)
          : null,
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
    );
  }
}

/* ===================== GLASS DIVIDER ===================== */

class GlassDivider extends StatelessWidget {
  final double thickness;
  final EdgeInsets margin;
  const GlassDivider({super.key, this.thickness = 1.0, this.margin = EdgeInsets.zero});
  @override
  Widget build(BuildContext context) => Container(
        margin: margin, height: thickness,
        color: isDarkOf(context) ? AppColors.outlineDark.withValues(alpha: 0.2) : Colors.black.withValues(alpha: 0.08),
      );
}

/* ===================== GLASS MINI CARD (original) ===================== */

class GlassMiniCard extends StatelessWidget {
  final String title;
  final String value;
  final IconData? icon;
  final Color? iconColor;
  final Color? backgroundColor;
  final double? height;
  final VoidCallback? onTap;
  const GlassMiniCard({super.key, required this.title, required this.value, this.icon, this.iconColor,
      this.backgroundColor, this.height, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final bg = isDark ? AppColors.surfaceVariantDark.withValues(alpha: 0.7) : AppColors.surfaceVariantLight.withValues(alpha: 0.7);
    final titleColor = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
    final valueColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
    final ic = iconColor ?? (isDark ? AppColors.primaryLight : AppColors.primary);
    final card = Container(
      height: height ?? 90,
      decoration: BoxDecoration(
        color: backgroundColor ?? bg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: isDark ? AppColors.outlineDark.withValues(alpha: 0.2) : AppColors.outlineLight.withValues(alpha: 0.2)),
        boxShadow: [BoxShadow(color: isDark ? Colors.black.withValues(alpha: 0.15) : Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisAlignment: MainAxisAlignment.center, children: [
          Row(children: [
            if (icon != null) ...[
              Container(
                width: 28, height: 28,
                decoration: BoxDecoration(color: ic.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(8)),
                child: Icon(icon, size: 16, color: ic),
              ),
              const SizedBox(width: 8),
            ],
            Expanded(child: Text(title, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: titleColor, fontWeight: FontWeight.w500, height: 1.2))),
          ]),
          const SizedBox(height: 8),
          Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 18, color: valueColor, fontWeight: FontWeight.w700, height: 1.1)),
        ]),
      ),
    );
    if (onTap == null) return card;
    return InkWell(borderRadius: BorderRadius.circular(16), onTap: onTap, child: card);
  }
}

/* ===================== additions in the same language ===================== */

/// Responsive grid of GlassMiniCards (2 columns on phones, up to 4 on wide screens).
class MiniCardGrid extends StatelessWidget {
  final List<Widget> children;
  const MiniCardGrid({super.key, required this.children});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, c) {
        final cols = c.maxWidth > 900 ? 4 : c.maxWidth > 560 ? 3 : 2;
        const gap = 12.0;
        final w = (c.maxWidth - gap * (cols - 1)) / cols;
        return Wrap(spacing: gap, runSpacing: gap, children: [for (final ch in children) SizedBox(width: w, child: ch)]);
      });
}

/// Small rounded status pill (same radius/opacity language as the original chips).
class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const StatusChip(this.label, {super.key, required this.color});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(20),
            border: Border.all(color: color.withValues(alpha: 0.35))),
        child: Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700)),
      );
}

class EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  const EmptyState(this.message, {super.key, this.icon = Icons.inbox_rounded});
  @override
  Widget build(BuildContext context) {
    final c = isDarkOf(context) ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 36),
      child: Column(children: [
        Icon(icon, size: 48, color: c.withValues(alpha: 0.6)),
        const SizedBox(height: 10),
        Text(message, textAlign: TextAlign.center, style: TextStyle(color: c, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class LoadingState extends StatelessWidget {
  const LoadingState({super.key});
  @override
  Widget build(BuildContext context) => const Padding(
      padding: EdgeInsets.symmetric(vertical: 48),
      child: Center(child: CircularProgressIndicator(color: AppColors.primary)));
}

class ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  final String retryLabel;
  const ErrorState(this.message, {super.key, this.onRetry, this.retryLabel = 'Retry'});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: GlassCard(
          child: Column(children: [
            const Icon(Icons.wifi_off_rounded, color: AppColors.error, size: 40),
            const SizedBox(height: 8),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
            if (onRetry != null) ...[
              const SizedBox(height: 12),
              TextButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: Text(retryLabel)),
            ],
          ]),
        ),
      );
}

/// Round glass icon button used in headers (notification bell / theme toggle style).
class GlassIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final bool badge;
  final String? tooltip;
  const GlassIconButton({super.key, required this.icon, required this.onTap, this.color, this.badge = false, this.tooltip});
  @override
  Widget build(BuildContext context) {
    final isDark = isDarkOf(context);
    final btn = GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark ? Colors.white.withValues(alpha: 0.15) : AppColors.primary.withValues(alpha: 0.1),
          border: Border.all(color: isDark ? Colors.white.withValues(alpha: 0.2) : AppColors.primary.withValues(alpha: 0.2)),
        ),
        child: Stack(alignment: Alignment.center, children: [
          Icon(icon, size: 24, color: color ?? (isDark ? Colors.white.withValues(alpha: 0.8) : AppColors.primary.withValues(alpha: 0.8))),
          if (badge)
            Positioned(right: 9, top: 9, child: Container(width: 10, height: 10,
                decoration: BoxDecoration(color: Colors.red, shape: BoxShape.circle,
                    border: Border.all(color: isDark ? Colors.black.withValues(alpha: 0.3) : Colors.white, width: 1.5)))),
        ]),
      ),
    );
    return tooltip == null ? btn : Tooltip(message: tooltip!, child: btn);
  }
}

/// Text field with the original login-form decoration (outline radius 12, primary focus 2px).
InputDecoration glassInput(BuildContext context, String label, {Widget? suffix, String? hint}) {
  final sub = isDarkOf(context) ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;
  return InputDecoration(
    labelText: label, hintText: hint,
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: sub.withValues(alpha: 0.3))),
    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide(color: sub.withValues(alpha: 0.3))),
    focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: const BorderSide(color: AppColors.primary, width: 2)),
    labelStyle: TextStyle(color: sub),
    contentPadding: const EdgeInsets.all(16),
    suffixIcon: suffix,
  );
}
