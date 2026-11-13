import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart'; // 🔥 استيراد الحزمة
import '../../theme/app_colors.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/glass_ui.dart';

class AttendanceExpandableCards extends StatefulWidget {
  final List<Map<String, dynamic>> days;
  final bool isDark;
  final Map<String, bool> expandedCards;
  final Function(String) onToggle;
  /// المدير / HR / المالك: edit the day's check-in / check-out times
  final void Function(Map<String, dynamic> day)? onEdit;

  const AttendanceExpandableCards({
    super.key,
    required this.days,
    required this.isDark,
    required this.expandedCards,
    required this.onToggle,
    this.onEdit,
  });

  @override
  State<AttendanceExpandableCards> createState() => _AttendanceExpandableCardsState();
}

class _AttendanceExpandableCardsState extends State<AttendanceExpandableCards> {
  // 🔥 دالة لفتح الخريطة
  Future<void> _openMap(String location) async {
    try {
      // تحليل الإحداثيات
      final parts = location.split(',');
      if (parts.length == 2) {
        final lat = parts[0].trim();
        final lng = parts[1].trim();

        // فتح تطبيق الخرائط
        final googleMapsUrl = 'https://www.google.com/maps/search/?api=1&query=$lat,$lng';
        final appleMapsUrl = 'https://maps.apple.com/?q=$lat,$lng';

        final url = Uri.parse(googleMapsUrl);

        if (await canLaunchUrl(url)) {
          await launchUrl(url, mode: LaunchMode.externalApplication);
        } else {
          throw 'لا يمكن فتح الخريطة';
        }
      } else {
        throw 'تنسيق الموقع غير صحيح';
      }
    } catch (e) {
      // يمكن إضافة رسالة خطأ للمستخدم
      debugPrint('خطأ في فتح الخريطة: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    // a phone: one under the other; a computer: 2–4 per row by the width
    return ResponsiveGrid(
      minTileWidth: 340,
      maxCols: 4,
      spacing: 12,
      children: [
        for (final day in widget.days)
          AttendanceExpandableCard(
            dayData: day,
            isDark: widget.isDark,
            isExpanded: widget.expandedCards[day['cardId'] ?? ''] ?? false,
            onTap: () => widget.onToggle(day['cardId'] ?? ''),
            openMap: _openMap, // 🔥 تمرير الدالة للبطاقة
            onEdit: widget.onEdit == null ? null : () => widget.onEdit!(day),
          ),
      ],
    );
  }
}

class AttendanceExpandableCard extends StatelessWidget {
  final Map<String, dynamic> dayData;
  final bool isDark;
  final bool isExpanded;
  final VoidCallback onTap;
  final Function(String) openMap; // 🔥 إضافة الدالة
  final VoidCallback? onEdit;

  const AttendanceExpandableCard({
    super.key,
    required this.dayData,
    required this.isDark,
    required this.isExpanded,
    required this.onTap,
    required this.openMap, // 🔥
    this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    // 🔥 ترجمة النصوص
    final attendanceStatus = dayData['status']?.toString() ?? '--';
    final startTime = AppLocalizations.of(context, 'start_time');
    final endTime = AppLocalizations.of(context, 'end_time');
    final workHours = AppLocalizations.of(context, 'work_hours');
    final lateLabel = AppLocalizations.of(context, 'late_time');
    final project = AppLocalizations.of(context, 'project');
    final location = AppLocalizations.of(context, 'location');
    final breakTime = AppLocalizations.of(context, 'break');
    final ceoConfirm = AppLocalizations.of(context, 'ceo_confirm');

    // 🔥 تحديد لون الحالة
    Color statusColor = Ar.grey;
    IconData statusIcon = Icons.info_outline;

    if (attendanceStatus.contains('منصرف')) {
      statusColor = isDark ? Ar.green.shade300 : Ar.green.shade700;
      statusIcon = Icons.check_circle;
    } else if (attendanceStatus.contains('اجازه') || attendanceStatus.contains('عطلة')) {
      statusColor = isDark ? Ar.amber.shade300 : Ar.amber.shade700;
      statusIcon = Icons.emoji_events;
    } else if (attendanceStatus.contains('غياب')) {
      statusColor = isDark ? Ar.red.shade300 : Ar.red.shade700;
      statusIcon = Icons.cancel;
    }

    // 🔥 دالة مساعدة لبناء عنصر التفاصيل
    Widget _buildDetailItem({
      required IconData icon,
      required String label,
      required String value,
      Color valueColor = Colors.black87,
      bool isImage = false,
      bool isLocation = false, // 🔥 إضافة خاصية للموقع
      String? imageUrl,
      String? locationData, // 🔥 بيانات الموقع للإحداثيات
    }) {
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: isDark ? Colors.black.withOpacity(0.3) : Colors.white,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 20, color: isDark ? Colors.white70 : Colors.black54),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                  if (isImage && imageUrl?.isNotEmpty == true)
                    GestureDetector(
                      onTap: () {
                        // عرض الصورة بالحجم الكامل
                        showDialog(
                          context: context,
                          builder: (dialogContext) => Dialog(
                            child: Container(
                              padding: const EdgeInsets.all(8),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Image.network(imageUrl!),
                                  TextButton(
                                    onPressed: () => Navigator.pop(dialogContext),
                                    child: Text(AppLocalizations.of(context, 'close')),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                      child: Container(
                        margin: const EdgeInsets.only(top: 4),
                        width: 100,
                        height: 100,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          image: DecorationImage(
                            image: NetworkImage(imageUrl!),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    )
                  else if (isLocation && locationData?.isNotEmpty == true)
                    GestureDetector(
                      onTap: () {
                        // فتح الخريطة عند الضغط على الموقع
                        openMap(locationData!);
                      },
                      child: Container(
                        margin: const EdgeInsets.only(top: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.open_in_new,
                              size: 16,
                              color: isDark ? Ar.info.shade300 : Ar.info.shade700,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              value,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: isDark ? Ar.info.shade300 : Ar.info.shade700,
                                decoration: TextDecoration.underline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    )
                  else
                    Text(
                      value,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: isDark ? Colors.white : valueColor,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // 🔥 دالة مساعدة لبناء قسم
    Widget _buildSection({
      required String title,
      required List<Widget> items,
    }) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isDark ? Colors.white.withOpacity(0.1) : Ar.grey[100],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: isDark ? Colors.white : Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            ...items,
          ],
        ),
      );
    }

    String _formatImage(String? imageUrl) {
      if (imageUrl == null || imageUrl.isEmpty || imageUrl == '--') {
        return 'لا توجد صورة';
      }
      return 'عرض الصورة';
    }

    // 🔥 التحقق من تنسيق الإحداثيات
    bool _isValidCoordinates(String? location) {
      if (location == null || location.isEmpty || location == '--') {
        return false;
      }
      final parts = location.split(',');
      if (parts.length != 2) return false;

      try {
        final lat = double.tryParse(parts[0].trim());
        final lng = double.tryParse(parts[1].trim());
        return lat != null && lng != null;
      } catch (e) {
        return false;
      }
    }

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: Glass.panel(isDark, r: 20),
        child: Column(
          children: [
            // 🔥 الجزء العلوي الثابت
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Container(
                    width: 50,
                    height: 50,
                    decoration: BoxDecoration(
                      color: statusColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(statusIcon, color: statusColor),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          dayData['date']?.toString() ?? '--',
                          style: TextStyle(
                            fontSize: 14,
                            color: isDark ? Colors.white70 : Colors.black54,
                          ),
                        ),
                        Text(
                          attendanceStatus,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: statusColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    isExpanded ? Icons.expand_less : Icons.expand_more,
                    color: isDark ? Colors.white70 : Colors.black54,
                  ),
                ],
              ),
            ),

            // 🔥 الجزء القابل للطي
            if (isExpanded)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: isDark ? Colors.black.withOpacity(0.3) : Ar.grey[50],
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(20),
                    bottomRight: Radius.circular(20),
                  ),
                ),
                child: Column(
                  children: [
                    // 🔥 قسم الحضور
                    _buildSection(
                      title: startTime,
                      items: [
                        _buildDetailItem(
                          icon: Icons.access_time,
                          label: 'الوقت',
                          value: dayData['startTime'] ?? '--',
                        ),
                        _buildDetailItem(
                          icon: Icons.photo,
                          label: 'الصورة',
                          value: _formatImage(dayData['startImage']),
                          isImage: true,
                          imageUrl: dayData['startImage']?.toString(),
                        ),
                        _buildDetailItem(
                          icon: Icons.location_on,
                          label: location,
                          value: _isValidCoordinates(dayData['startLocation'])
                              ? 'عرض الموقع على الخريطة'
                              : (dayData['startLocation'] ?? '--'),
                          isLocation: _isValidCoordinates(dayData['startLocation']),
                          locationData: dayData['startLocation']?.toString(),
                        ),
                        _buildDetailItem(
                          icon: Icons.verified,
                          label: ceoConfirm,
                          value: dayData['startCeoConfirm'] ?? '--',
                          valueColor: dayData['startCeoConfirm'] != '--'
                              ? Ar.green
                              : Ar.grey,
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 🔥 قسم الانصراف
                    _buildSection(
                      title: endTime,
                      items: [
                        _buildDetailItem(
                          icon: Icons.access_time,
                          label: 'الوقت',
                          value: dayData['endTime'] ?? '--',
                        ),
                        _buildDetailItem(
                          icon: Icons.photo,
                          label: 'الصورة',
                          value: _formatImage(dayData['endImage']),
                          isImage: true,
                          imageUrl: dayData['endImage']?.toString(),
                        ),
                        _buildDetailItem(
                          icon: Icons.location_on,
                          label: location,
                          value: _isValidCoordinates(dayData['endLocation'])
                              ? 'عرض الموقع على الخريطة'
                              : (dayData['endLocation'] ?? '--'),
                          isLocation: _isValidCoordinates(dayData['endLocation']),
                          locationData: dayData['endLocation']?.toString(),
                        ),
                        _buildDetailItem(
                          icon: Icons.verified,
                          label: ceoConfirm,
                          value: dayData['endCeoConfirm'] ?? '--',
                          valueColor: dayData['endCeoConfirm'] != '--'
                              ? Ar.green
                              : Ar.grey,
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    if ((dayData['correctedBy'] ?? '').toString().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text('تم التعديل بواسطة ${dayData['correctedBy']}',
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: Ar.amber)),
                      ),
                    if (onEdit != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: onEdit,
                            icon: const Icon(Icons.edit_calendar_rounded),
                            label: const Text('تعديل وقت الحضور / الانصراف', style: TextStyle(fontWeight: FontWeight.w800)),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            ),
                          ),
                        ),
                      ),

                    // 🔥 مواعيد الدوام المطلوبة
                    _buildSection(
                      title: 'مواعيد العمل',
                      items: [
                        _buildDetailItem(
                          icon: Icons.login_rounded,
                          label: 'بداية العمل',
                          value: '${dayData['scheduleStart'] ?? '--'}',
                        ),
                        _buildDetailItem(
                          icon: Icons.logout_rounded,
                          label: 'نهاية العمل',
                          value: '${dayData['scheduleEnd'] ?? '--'}',
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 🔥 أذونات الخروج والزيارات
                    _buildSection(
                      title: 'أذونات الخروج والزيارات',
                      items: [
                        if ((dayData['outings'] is List ? dayData['outings'] as List : const []).isEmpty)
                          _buildDetailItem(icon: Icons.directions_walk_rounded, label: 'لا يوجد', value: '--'),
                        for (final o in (dayData['outings'] is List ? dayData['outings'] as List : const []).whereType<Map>())
                          _buildDetailItem(
                            icon: o['kind'] == 'visit' ? Icons.location_city_rounded : Icons.timelapse_rounded,
                            label: '${o['label']}',
                            value: '${o['text']}',
                            valueColor: Ar.green,
                          ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // 🔥 قسم ملخص العمل
                    _buildSection(
                      title: 'ملخص العمل',
                      items: [
                        _buildDetailItem(
                          icon: Icons.timer,
                          label: workHours,
                          value: dayData['workHours'] ?? '--',
                          valueColor: Ar.info,
                        ),
                        _buildDetailItem(
                          icon: Icons.timer_outlined,
                          label: lateLabel,
                          value: dayData['lateTime'] ?? '--',
                          valueColor: Ar.amber,
                        ),
                        _buildDetailItem(
                          icon: Icons.work,
                          label: project,
                          value: '${dayData['projectName']}',
                          valueColor: Ar.accent,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}