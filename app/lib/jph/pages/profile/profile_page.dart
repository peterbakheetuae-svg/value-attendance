// lib/pages/profile/profile_page.dart
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../pages/employees/employees_page.dart';
import '../../services/app_controller.dart';
import '../../l10n/app_localizations.dart';
import '../../theme/app_colors.dart';
import '../../widgets/app_background.dart';
import '../../widgets/glass_ui_widgets.dart';
import '../../widgets/glass_bottom_nav.dart';
import '../../services/profile_api.dart';
import '../attendance/attendance_report_page.dart';
import '../dashboard_employers/dashboard_page.dart';
import '../settings/settings_page.dart';
import 'edit_profile_page.dart';
import '../../widgets/employee_files.dart';

class ProfilePage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;
  final String photo;

  const ProfilePage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
    this.photo = "",
  });

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool loading = true;
  Map<String, dynamic> data = {};
  String source = 'employee'; // default

  @override
  void initState() {
    super.initState();
    loadProfile();
  }

  Future<void> loadProfile() async {
    final res = await ProfileApi.load(widget.uid);
    if (!mounted) return;

    if (res["success"] == true) {
      setState(() {
        data = res;
        source = res["source"] ?? 'employee';
        loading = false;
      });

      // Update photo in AppController if changed
      if (res["photo"] != null && res["photo"].toString().isNotEmpty) {
        final appController = Provider.of<AppController>(context, listen: false);
        appController.saveUserPhoto(res["photo"]);
      }
    } else {
      setState(() => loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(res["message"] ?? "Error loading data")),
      );
    }
  }

  void onBottomNavTap(int index) {
    if (index == 4) return;

    final page = switch (index) {
      0 => DashboardPage(uid: widget.uid, name: widget.name, role: widget.role),
      1 => AttendanceReportPage(uid: widget.uid, name: widget.name, role: widget.role),
      2 => EmployeesPage(currentUserId: widget.uid, currentUserName: widget.name, currentUserRole: widget.role),
      3 => SettingsPage(uid: widget.uid, name: widget.name, role: widget.role),
      _ => null,
    };

    if (page != null) {
      Navigator.push(context, MaterialPageRoute(builder: (_) => page));
    }
  }

  double _levelPercent() {
    if (source != 'employee') return 0.0;
    final rawStr = (data["level"] ?? "0").toString().trim();
    final v = double.tryParse(rawStr.replaceAll("%", "")) ?? 0.0;
    if (v > 1.0) return (v / 100.0).clamp(0.0, 1.0);
    return v.clamp(0.0, 1.0);
  }

  String _initialsFromName(String name) {
    final s = name.trim();
    if (s.isEmpty) return "??";
    final parts = s.split(RegExp(r"\s+")).where((e) => e.isNotEmpty).toList();
    if (parts.isEmpty) return "??";
    String a = parts.first.characters.first;
    String b = parts.length > 1 ? parts[1].characters.first : "";
    String out = (a + b).toUpperCase();
    if (out.length == 1) out = "${out}M";
    if (out.length > 2) out = out.substring(0, 2);
    return out;
  }

  String tr(BuildContext context, String key) {
    if (key.isEmpty) return "--";
    return AppLocalizations.of(context, key);
  }

  Widget _headerCard(BuildContext context, bool isDark, Color primaryColor, Color textColor, Color subduedTextColor) {
    return Consumer<AppController>(
      builder: (context, appController, child) {
        final controllerPhoto = appController.userPhoto;
        final photoUrl = controllerPhoto ?? (data["photo"] ?? widget.photo).toString();
        final initials = _initialsFromName(data["name"] ?? widget.name);
        final percent = _levelPercent();
        final percentText = "${(percent * 100).round()}%";

        return GlassCard(
          radius: 24,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      data["role"] ?? widget.role,
                      style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: textColor),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      "${AppLocalizations.of(context, 'employee_id')} ${data["uid"] ?? widget.uid}",
                      style: TextStyle(color: subduedTextColor, fontSize: 14),
                    ),
                    const SizedBox(height: 14),
                    SizedBox(
                      height: 46,
                      child: ElevatedButton.icon(
                        onPressed: () => _navigateToEditProfile(context),
                        icon: Icon(Icons.edit_outlined, size: 18, color: Colors.white),
                        label: Text(
                          AppLocalizations.of(context, 'edit_account'),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryColor,
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 14),
              _ProgressRingAvatar(
                size: 108,
                strokeWidth: 8,
                percent: percent,
                percentText: percentText,
                imageUrl: photoUrl,
                initials: initials,
                isDark: isDark,
                primaryColor: primaryColor,
              ),
            ],
          ),
        );
      },
    );
  }

  void _navigateToEditProfile(BuildContext context) async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => EditProfilePage(
          uid: widget.uid,
          currentData: data,
          source: source,
        ),
      ),
    );
    if (result == true) {
      loadProfile(); // reload after edit
    }
  }

  Widget _section(String title, List<Widget> rows, Color textColor) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: textColor)),
        const SizedBox(height: 12),
        GlassCard(radius: 24, padding: const EdgeInsets.all(16), child: Column(children: rows)),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _row(IconData icon, String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Text("$label : $value", style: TextStyle(fontSize: 14, color: color)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;
        final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark ? AppColors.onSurfaceVariantDark : AppColors.onSurfaceVariantLight;

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? TextDirection.rtl : TextDirection.ltr,
            child: Scaffold(
              extendBody: true,
              backgroundColor: Colors.transparent,
              bottomNavigationBar: GlassBottomNav(currentIndex: 4, onTap: onBottomNavTap),
              body: loading
                  ? Center(child: CircularProgressIndicator(color: primaryColor))
                  : SafeArea(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const SizedBox(height: 25),
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        AppLocalizations.of(context, 'profile'),
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: textColor),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _headerCard(context, isDark, primaryColor, textColor, subduedTextColor),
                    const SizedBox(height: 24),

                    if (source == 'employee') ...[
                      // Employee sections
                      _section(
                        AppLocalizations.of(context, 'professional_info'),
                        [
                          _row(Icons.email, AppLocalizations.of(context, 'email'), data["email"] ?? "--", subduedTextColor),
                          _row(Icons.phone, AppLocalizations.of(context, 'phone'), data["phone"] ?? "--", subduedTextColor),
                          _row(Icons.event, AppLocalizations.of(context, 'join_date'), data["joinDate"] ?? "--", subduedTextColor),
                          _row(Icons.work, AppLocalizations.of(context, 'role'), tr(context, data["role"] ?? ""), subduedTextColor),
                          _row(Icons.account_tree, AppLocalizations.of(context, 'follow_to'), data["followToName"] ?? data["followTo"] ?? "--", subduedTextColor),
                          _row(Icons.payments, AppLocalizations.of(context, 'accounting'), tr(context, data["payType"] ?? "--"), subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'salary_data'),
                        [
                          _row(Icons.monetization_on, AppLocalizations.of(context, 'daily_rate'), data["dailyRate"] ?? "--", subduedTextColor),
                          _row(Icons.account_balance_wallet, AppLocalizations.of(context, 'salary'), data["salary"] ?? "--", subduedTextColor),
                          _row(Icons.flag, AppLocalizations.of(context, 'start_salary'), data["startSalary"] ?? "--", subduedTextColor),
                          _row(Icons.trending_up, AppLocalizations.of(context, 'increment'), data["increment"] ?? "--", subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'work_system'),
                        [
                          _row(Icons.weekend, AppLocalizations.of(context, 'day_off'), data["dayOff"] ?? "--", subduedTextColor),
                          _row(Icons.access_time, AppLocalizations.of(context, 'work_hours'), data["workHours"] ?? "--", subduedTextColor),
                          _row(Icons.remove_circle, AppLocalizations.of(context, 'absence_factor'), data["absenceFactor"] ?? "--", subduedTextColor),
                          _row(Icons.add_circle, AppLocalizations.of(context, 'overtime_factor'), data["overtimeFactor"] ?? "--", subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'bank_info'),
                        [
                          _row(Icons.account_balance, AppLocalizations.of(context, 'bank_name'), data["bankName"] ?? "--", subduedTextColor),
                          _row(Icons.person, AppLocalizations.of(context, 'account_holder'), data["accountHolder"] ?? "--", subduedTextColor),
                          _row(Icons.numbers, AppLocalizations.of(context, 'iban'), data["iban"] ?? "--", subduedTextColor),
                          _row(Icons.pin, AppLocalizations.of(context, 'account_number'), data["accountNumber"] ?? "--", subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'additional_info'),
                        [
                          _row(Icons.star, AppLocalizations.of(context, 'level'), data["level"] ?? "--", subduedTextColor),
                          _row(Icons.info, AppLocalizations.of(context, 'employee_status'), data["employeeStatus"] ?? "--", subduedTextColor),
                          _row(Icons.verified, AppLocalizations.of(context, 'validity'), data["validity"] ?? "--", subduedTextColor),
                          _row(Icons.business, AppLocalizations.of(context, 'company'), data["companyName"] ?? data["companyId"] ?? "--", subduedTextColor),
                          _row(Icons.person_add, AppLocalizations.of(context, 'created_by'), data["createdByName"] ?? data["createdBy"] ?? "--", subduedTextColor),
                          _row(Icons.update, AppLocalizations.of(context, 'last_modified'), "${data["lastModifiedDate"] ?? "--"} (${data["lastModifiedByName"] ?? data["lastModifiedBy"] ?? "--"})", subduedTextColor),
                        ],
                        textColor,
                      ),
                    ] else ...[
                      // Employer sections
                      _section(
                        AppLocalizations.of(context, 'personal_info'),
                        [
                          _row(Icons.email, AppLocalizations.of(context, 'email'), data["email"] ?? "--", subduedTextColor),
                          _row(Icons.phone, AppLocalizations.of(context, 'phone'), data["phone"] ?? "--", subduedTextColor),
                          _row(Icons.work, AppLocalizations.of(context, 'role'), tr(context, data["role"] ?? ""), subduedTextColor),
                          _row(Icons.percent, AppLocalizations.of(context, 'ownership_percent'), data["ownershipPercent"] ?? "--", subduedTextColor),
                          _row(Icons.trending_up, AppLocalizations.of(context, 'profit_percent'), data["profitPercent"] ?? "--", subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'partnership_dates'),
                        [
                          _row(Icons.event, AppLocalizations.of(context, 'partnership_start'), data["partnershipStart"] ?? "--", subduedTextColor),
                          _row(Icons.event_busy, AppLocalizations.of(context, 'partnership_end'), data["partnershipEnd"] ?? "--", subduedTextColor),
                          _row(Icons.calendar_today, AppLocalizations.of(context, 'created_at'), data["createdAt"] ?? "--", subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'bank_info'),
                        [
                          _row(Icons.account_balance, AppLocalizations.of(context, 'bank_name'), data["bankName"] ?? "--", subduedTextColor),
                          _row(Icons.person, AppLocalizations.of(context, 'account_holder'), data["accountHolder"] ?? "--", subduedTextColor),
                          _row(Icons.numbers, AppLocalizations.of(context, 'iban'), data["iban"] ?? "--", subduedTextColor),
                          _row(Icons.pin, AppLocalizations.of(context, 'account_number'), data["accountNumber"] ?? "--", subduedTextColor),
                        ],
                        textColor,
                      ),
                      _section(
                        AppLocalizations.of(context, 'additional_info'),
                        [
                          _row(Icons.note, AppLocalizations.of(context, 'notes'), data["notes"] ?? "--", subduedTextColor),
                          _row(Icons.verified, AppLocalizations.of(context, 'validity'), data["validity"] ?? "--", subduedTextColor),
                          _row(Icons.info, AppLocalizations.of(context, 'status'), data["status"] ?? "--", subduedTextColor),
                          _row(Icons.business, AppLocalizations.of(context, 'company'), data["companyName"] ?? data["companyId"] ?? "--", subduedTextColor),
                          _row(Icons.person_add, AppLocalizations.of(context, 'created_by'), data["createdByName"] ?? data["createdBy"] ?? "--", subduedTextColor),
                          _row(Icons.update, AppLocalizations.of(context, 'last_modified'), "${data["lastModifiedDate"] ?? "--"} (${data["lastModifiedByName"] ?? data["lastModifiedBy"] ?? "--"})", subduedTextColor),
                        ],
                        textColor,
                      ),
                    ],

                    // own documents + custody (read-only for the employee)
                    EmployeeDocumentsSection(employeeId: widget.uid),
                    EmployeeCustodySection(employeeId: widget.uid),

                    const SizedBox(height: 100),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// The custom painter and helper widgets remain the same as before.
class _ProgressRingAvatar extends StatelessWidget {
  final double size;
  final double strokeWidth;
  final double percent;
  final String percentText;
  final String imageUrl;
  final String initials;
  final bool isDark;
  final Color primaryColor;

  const _ProgressRingAvatar({
    required this.size,
    required this.strokeWidth,
    required this.percent,
    required this.percentText,
    required this.imageUrl,
    required this.initials,
    required this.isDark,
    required this.primaryColor,
  });

  @override
  Widget build(BuildContext context) {
    final inner = size - (strokeWidth * 2);
    final hasPhoto = imageUrl.trim().isNotEmpty;
    final ringBgColor = isDark ? Colors.white.withOpacity(0.2) : Colors.white.withOpacity(0.9);
    final progressColor = isDark ? AppColors.primaryLight : AppColors.primaryDark;
    final badgeColor = isDark ? AppColors.surfaceVariantDark : AppColors.primaryDark;
    final initialsColor = isDark ? AppColors.primaryLight : AppColors.primary;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _RingPainter(
              percent: percent.clamp(0.0, 1.0),
              strokeWidth: strokeWidth,
              ringBgColor: ringBgColor,
              progressColor: progressColor,
            ),
          ),
          Positioned(
            left: strokeWidth,
            top: strokeWidth,
            child: Container(
              width: inner,
              height: inner,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDark ? AppColors.surfaceVariantDark.withOpacity(0.3) : Colors.teal.shade50,
              ),
              child: ClipOval(
                child: hasPhoto
                    ? Image.network(imageUrl, fit: BoxFit.cover, errorBuilder: (_, __, ___) => _InitialsCircle(initials: initials, size: inner, color: initialsColor))
                    : _InitialsCircle(initials: initials, size: inner, color: initialsColor),
              ),
            ),
          ),
          Positioned(
            bottom: -8,
            left: 12,
            right: 12,
            child: Container(
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(color: badgeColor, borderRadius: BorderRadius.circular(18)),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(percentText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)),
                  const SizedBox(width: 8),
                  const Icon(Icons.star, color: Colors.amber, size: 18),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InitialsCircle extends StatelessWidget {
  final String initials;
  final double size;
  final Color color;
  const _InitialsCircle({required this.initials, required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Center(child: Text(initials, style: TextStyle(fontSize: size * 0.35, fontWeight: FontWeight.w900, color: color)));
  }
}

class _RingPainter extends CustomPainter {
  final double percent;
  final double strokeWidth;
  final Color ringBgColor;
  final Color progressColor;

  _RingPainter({required this.percent, required this.strokeWidth, required this.ringBgColor, required this.progressColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (math.min(size.width, size.height) / 2) - (strokeWidth / 2);
    final bgPaint = Paint()
      ..color = ringBgColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, bgPaint);
    final fgPaint = Paint()
      ..color = progressColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    final startAngle = -math.pi / 2;
    final sweepAngle = (2 * math.pi) * percent;
    canvas.drawArc(Rect.fromCircle(center: center, radius: radius), startAngle, sweepAngle, false, fgPaint);
  }

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) {
    return oldDelegate.percent != percent ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.ringBgColor != ringBgColor ||
        oldDelegate.progressColor != progressColor;
  }
}