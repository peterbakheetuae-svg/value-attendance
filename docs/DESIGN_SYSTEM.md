# Design system (copied from JPH Attendance)

Source (read-only): `D:\JPH\jph_attendance\jph-attendance-v2\app\lib\{theme,widgets}` and `app\assets`.

| Token / component | Original | New project |
|---|---|---|
| Colours | `theme/app_colors.dart` — primary #4F46E5, secondary #14B8A6, accent #F59E0B, error #EF4444, success #10B981, slate neutrals | `design/app_colors.dart` (verbatim; `withOpacity`→`withValues`) |
| Light / dark themes | `theme/light_theme.dart`, `dark_theme.dart` — Cairo text theme, card radius 16, button radius 12 | `design/light_theme.dart`, `dark_theme.dart` (verbatim minus deprecated background fields) |
| Background | `widgets/app_background.dart` — `bg/light_bg.png` / `bg/dark_bg.png`, top/bottom gradient overlay 0.08/0.10 (light) 0.35/0.55 (dark) | `design/glass.dart › AppBackground` (same values) |
| Glass card | blur 14 (light) / 18 (dark), radius 26, border white 30 % / outlineDark 30 %, shadow blur 28 offset (0,14) | `GlassCard` (same) |
| Mini stat card | radius 16, 90 px, icon tile 28 px radius 8 | `GlassMiniCard` (same) |
| Primary button | 52 px, radius 16, w900 16 px, white spinner | `design/primary_button.dart` |
| Bottom navigation | radius 40, height 72, blur 12/14, active pill radius 22 with label | `design/glass_bottom_nav.dart` (items now per role) |
| Inputs | outline radius 12, focus primary 2 px | `glassInput()` |
| Header | 44 px glass circle bell, centred name/date, avatar | `GlassIconButton`, dashboard header |
| Fonts | Cairo Regular/SemiBold/Bold | `assets/fonts` (same files) |
| Logo, avatar | `images/logo.png`, `avatar.png` | same files |

New widgets (`MiniCardGrid`, `StatusChip`, `EmptyState`, `LoadingState`, `ErrorState`, `GlassPage`, `showGlassSheet`)
are built only from the tokens above.
