import 'dart:ui' as ui;
import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/app_controller.dart';
import '../services/advance_request_api.dart';
import '../widgets/app_background.dart';
import '../theme/app_colors.dart';
import '../l10n/app_localizations.dart';
import '../widgets/payouts_widgets.dart';
import 'cash/cashbox_hub_page.dart';
import '../widgets/jph_form_ui.dart';
import 'cash/cash_page.dart';
import '../widgets/swipe_tabs.dart';
import '../widgets/adjustment_form.dart';
import '../widgets/glass_ui.dart';

class AdvanceRequestPage extends StatefulWidget {
  final String uid;
  final String name;
  final String role;

  const AdvanceRequestPage({
    super.key,
    required this.uid,
    required this.name,
    required this.role,
  });

  @override
  State<AdvanceRequestPage> createState() => _AdvanceRequestPageState();
}

class _AdvanceRequestPageState extends State<AdvanceRequestPage> {
  final ImagePicker _picker = ImagePicker();
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _amountController = TextEditingController();

  // State variables
  String _requestType = 'سلفة';
  String _selectedMonth = 'يناير';
  double _amount = 0.0;
  String _note = '';
  File? _selectedImage;
  bool _isSubmitting = false;
  final _cashMonth = ValueNotifier<DateTime>(DateTime(DateTime.now().year, DateTime.now().month));


  // عمولة الصفقة اتنقلت لتبويب "مبيعات" (بيع + طلب عمولة)
  final List<String> _requestTypes = [
    'سلفة',
    'مصاريف عمل',
  ];

  final List<String> _months = [
    'يناير',
    'فبراير',
    'مارس',
    'أبريل',
    'مايو',
    'يونيو',
    'يوليو',
    'أغسطس',
    'سبتمبر',
    'أكتوبر',
    'نوفمبر',
    'ديسمبر',
  ];

  final Map<String, IconData> _requestTypeIcons = {
    'سلفة': Icons.account_balance_wallet_rounded,
    'مصاريف عمل': Icons.business_center_rounded,
    'عمولة صفقة': Icons.handshake_rounded,
  };

  final Map<String, Color> _requestTypeColors = {
    'سلفة': Ar.info,
    'مصاريف عمل': Ar.accent,
    'عمولة صفقة': Ar.green,
  };

  @override
  void initState() {
    super.initState();
    // تعيين الشهر الحالي تلقائياً
    final now = DateTime.now();
    _selectedMonth = _months[now.month - 1];
  }

  @override
  void dispose() {
    _amountController.dispose();
    _cashMonth.dispose();
    super.dispose();
  }

  String _tr(String key) {
    try {
      return AppLocalizations.of(context, key);
    } catch (e) {
      return key;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppController>(
      builder: (context, appController, _) {
        final isDark = appController.isDark;
        final isRTL = appController.isRTL;

        final primaryColor = isDark ? AppColors.primaryLight : AppColors.primary;
        final textColor = isDark ? AppColors.onSurfaceDark : AppColors.onSurfaceLight;
        final subduedTextColor = isDark
            ? AppColors.onSurfaceVariantDark
            : AppColors.onSurfaceVariantLight;

        return AppBackground(
          child: Directionality(
            textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: Column(
                  children: [
                    // Header
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      child: Row(
                        children: [
                          GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: Glass.panel(isDark, r: 14),
                              child: Icon(
                                isRTL ? Icons.arrow_forward_ios_rounded : Icons.arrow_back_ios_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                          const Spacer(),
                          Text(
                            'طلبات مالية',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: textColor,
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => CashboxHubPage(
                                    uid: widget.uid,
                                    name: widget.name,
                                    role: widget.role,
                                  ),
                                ),
                              );
                            },
                            child: Container(
                              width: 46,
                              height: 46,
                              decoration: Glass.panel(isDark, r: 14),
                              child: Icon(
                                Icons.summarize_rounded,
                                color: textColor,
                                size: 22,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 6),

                    Expanded(
                      child: SwipeTabs(
                        isDark: isDark,
                        tabs: [
                          ('طلب', Icons.request_page_rounded),
                          if (AdjustmentsTab.visible) ('علاوة / خصم', Icons.tune_rounded),
                          if (CashboxHubPage.canCash) ('الخزنة', Icons.account_balance_wallet_rounded),
                        ],
                        pages: [
                          _requestTab(isDark, isRTL, primaryColor, textColor, subduedTextColor),
                          if (AdjustmentsTab.visible) AdjustmentsTab(isDark: isDark),
                          // الخزنة: المتاح (بنك / نقدي) والدخل والمصروفات — المبيعات بقت في «المشاريع ← المبيعات»
                          if (CashboxHubPage.canCash) CashPage(embedded: true, month: _cashMonth),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _requestTab(bool isDark, bool isRTL, Color primaryColor, Color textColor, Color subduedTextColor) {
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          return SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            padding: const EdgeInsets.all(16),
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                minHeight: constraints.maxHeight,
                              ),
                              child: IntrinsicHeight(
                                child: Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      const MyPayoutsSection(),
                                      // زر الانتقال السريع إلى ملخص المالية
                                      GestureDetector(
                                        onTap: () {
                                          Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (context) => CashboxHubPage(
                                                uid: widget.uid,
                                                name: widget.name,
                                                role: widget.role,
                                              ),
                                            ),
                                          );
                                        },
                                        child: Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                          decoration: Glass.panel(isDark, r: 20),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 44,
                                                height: 44,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(12),
                                                  color: isDark ? Ar.info.shade800 : Ar.info.shade100,
                                                ),
                                                child: Icon(
                                                  Icons.summarize_rounded,
                                                  color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                  size: 24,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      CashboxHubPage.canCash ? 'الخزنة' : 'ملخص المالية',
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.w800,
                                                        color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      'كل الطلبات والمصروفات المالية',
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: isDark ? Ar.info.shade200 : Ar.info.shade600,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              Icon(
                                                isRTL ? Icons.arrow_back_ios_rounded : Icons.arrow_forward_ios_rounded,
                                                color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                size: 18,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),

                                      // الطلب دايماً باسم اللي عامله (مفيش اختيار موظف): بيروح للمدير العام / المالك
                                      // يوافق، وبعدها الموارد البشرية تصرف، وإنت تأكد "تم الاستلام" من الخزنة ← الطلبات

                                      // بيانات طلب السلفة/المصاريف
                                      Text(
                                        'بيانات طلب السلفة/المصاريف',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 16),

                                      // نوع الطلب
                                      _buildRequestTypeButton(isDark, textColor, subduedTextColor, primaryColor),

                                      const SizedBox(height: 16),

                                      ...[
                                      // الشهر
                                      _buildMonthButton(isDark, textColor, subduedTextColor, primaryColor),

                                      const SizedBox(height: 16),

                                      // المبلغ
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                        decoration: Glass.panel(isDark, r: 20),
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.end,
                                          children: [
                                            Text(
                                              'المبلغ *',
                                              style: TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                                color: subduedTextColor,
                                              ),
                                            ),
                                            const SizedBox(height: 8),
                                            TextFormField(
                                              controller: _amountController,
                                              keyboardType: TextInputType.number,
                                              textInputAction: TextInputAction.done,
                                              decoration: InputDecoration(
                                                hintText: 'أدخل المبلغ',
                                                hintStyle: TextStyle(
                                                  color: subduedTextColor,
                                                  fontSize: 16,
                                                ),
                                                border: InputBorder.none,
                                                prefixIcon: Icon(
                                                  Icons.attach_money_rounded,
                                                  color: primaryColor,
                                                  size: 22,
                                                ),
                                                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                              ),
                                              style: TextStyle(
                                                fontSize: 22,
                                                fontWeight: FontWeight.w800,
                                                color: textColor,
                                              ),
                                              onChanged: (value) {
                                                setState(() {
                                                  _amount = double.tryParse(value) ?? 0.0;
                                                });
                                              },
                                              validator: (value) {
                                                if (value == null || value.trim().isEmpty) {
                                                  return 'هذا الحقل مطلوب';
                                                }
                                                final amount = double.tryParse(value);
                                                if (amount == null || amount <= 0) {
                                                  return 'يرجى إدخال مبلغ صحيح';
                                                }
                                                return null;
                                              },
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 8),

                                      // عرض المبلغ بالكلمات (اختياري)
                                      if (_amount > 0)
                                        Container(
                                          padding: const EdgeInsets.all(12),
                                          decoration: BoxDecoration(
                                            color: isDark ? Ar.green.shade900.withOpacity(0.3) : Ar.green.shade50,
                                            borderRadius: BorderRadius.circular(12),
                                            border: Border.all(
                                              color: isDark ? Ar.green.shade700 : Ar.green.shade200,
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Icon(
                                                Icons.check_circle_rounded,
                                                color: isDark ? Ar.green.shade300 : Ar.green.shade600,
                                                size: 18,
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: Text(
                                                  'المبلغ: $_amount جنيه ',
                                                  style: TextStyle(
                                                    fontSize: 14,
                                                    fontWeight: FontWeight.w600,
                                                    color: isDark ? Ar.green.shade300 : Ar.green.shade800,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),

                                      const SizedBox(height: 24),

                                      // ملاحظة ذكية
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 16),
                                        padding: const EdgeInsets.all(16),
                                        decoration: Glass.panel(isDark, r: 20),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                color: isDark ? Ar.info.shade800 : Ar.info.shade50,
                                              ),
                                              child: Icon(
                                                Icons.info_rounded,
                                                color: isDark ? Ar.info.shade300 : Ar.info,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    'ملاحظة ذكية',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? Ar.info.shade300 : Ar.info.shade800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'عند طلب سلفة، سيتم خصم المبلغ من الراتب الشهري للموظف.',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                      color: isDark ? Ar.info.shade200 : Ar.info.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 16),

                                      // ملاحظة
                                      Text(
                                        'ملاحظة (اختياري)',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 8),

                                      Container(
                                        margin: const EdgeInsets.only(bottom: 16),
                                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                        decoration: Glass.panel(isDark, r: 20),
                                        child: TextFormField(
                                          maxLines: 4,
                                          minLines: 3,
                                          decoration: InputDecoration(
                                            hintText: 'اكتب ملاحظة توضيحية هنا...',
                                            hintStyle: TextStyle(
                                              color: subduedTextColor,
                                              fontSize: 16,
                                            ),
                                            border: InputBorder.none,
                                            contentPadding: const EdgeInsets.symmetric(vertical: 12),
                                          ),
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                            color: textColor,
                                          ),
                                          onChanged: (value) => _note = value,
                                        ),
                                      ),

                                      const SizedBox(height: 8),

                                      // نصيحة
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 16),
                                        padding: const EdgeInsets.all(16),
                                        decoration: Glass.panel(isDark, r: 20),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                color: isDark ? Ar.amber.shade800 : Ar.amber.shade50,
                                              ),
                                              child: Icon(
                                                Icons.lightbulb_rounded,
                                                color: isDark ? Ar.amber.shade300 : Ar.amber,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    'نصيحة',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? Ar.amber.shade300 : Ar.amber.shade800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'أضف ملاحظة توضيحية تساعد في تسريع عملية المراجعة.',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                      color: isDark ? Ar.amber.shade200 : Ar.amber.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      const SizedBox(height: 16),

                                      // المرفق
                                      Text(
                                        'المرفق (اختياري)',
                                        style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.w800,
                                          color: textColor,
                                        ),
                                      ),
                                      const SizedBox(height: 8),

                                      if (_selectedImage == null)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                                          decoration: Glass.panel(isDark, r: 20),
                                          child: GestureDetector(
                                            onTap: _pickImage,
                                            child: Row(
                                              children: [
                                                Container(
                                                  width: 44,
                                                  height: 44,
                                                  decoration: BoxDecoration(
                                                    borderRadius: BorderRadius.circular(12),
                                                    color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFEDEAE5),
                                                  ),
                                                  child: Icon(
                                                    Icons.add_photo_alternate_rounded,
                                                    color: primaryColor,
                                                    size: 22,
                                                  ),
                                                ),
                                                const SizedBox(width: 12),
                                                Expanded(
                                                  child: Column(
                                                    crossAxisAlignment: CrossAxisAlignment.end,
                                                    children: [
                                                      Text(
                                                        'إضافة صورة',
                                                        style: TextStyle(
                                                          fontSize: 16,
                                                          fontWeight: FontWeight.w800,
                                                          color: textColor,
                                                        ),
                                                      ),
                                                      const SizedBox(height: 4),
                                                      Text(
                                                        'صورة الفاتورة أو المستند الداعم',
                                                        style: TextStyle(
                                                          fontSize: 14,
                                                          fontWeight: FontWeight.w600,
                                                          color: subduedTextColor,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Icon(
                                                  isRTL ? Icons.arrow_back_ios_rounded : Icons.arrow_forward_ios_rounded,
                                                  color: subduedTextColor,
                                                  size: 26,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),

                                      if (_selectedImage != null) ...[
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 16),
                                          padding: const EdgeInsets.all(16),
                                          decoration: Glass.panel(isDark, r: 20),
                                          child: Row(
                                            children: [
                                              Container(
                                                width: 60,
                                                height: 60,
                                                decoration: BoxDecoration(
                                                  borderRadius: BorderRadius.circular(12),
                                                  image: DecorationImage(
                                                    image: FileImage(_selectedImage!),
                                                    fit: BoxFit.cover,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Expanded(
                                                child: Column(
                                                  crossAxisAlignment: CrossAxisAlignment.end,
                                                  children: [
                                                    Text(
                                                      'الصورة المرفقة',
                                                      style: TextStyle(
                                                        fontSize: 16,
                                                        fontWeight: FontWeight.w800,
                                                        color: textColor,
                                                      ),
                                                    ),
                                                    const SizedBox(height: 4),
                                                    Text(
                                                      _selectedImage!.path.split('/').last,
                                                      style: TextStyle(
                                                        fontSize: 12,
                                                        color: subduedTextColor,
                                                      ),
                                                      overflow: TextOverflow.ellipsis,
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(width: 10),
                                              IconButton(
                                                icon: Icon(
                                                  Icons.delete_rounded,
                                                  color: isDark ? const Color(0xFFFF7D6E) : const Color(0xFFE5604F),
                                                  size: 24,
                                                ),
                                                onPressed: () {
                                                  setState(() {
                                                    _selectedImage = null;
                                                  });
                                                },
                                              ),
                                            ],
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        GestureDetector(
                                          onTap: _pickImage,
                                          child: Text(
                                            'تغيير الصورة',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w600,
                                              color: primaryColor,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 16),
                                      ],

                                      // ملاحظة للمدير
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 24),
                                        padding: const EdgeInsets.all(16),
                                        decoration: Glass.panel(isDark, r: 20),
                                        child: Row(
                                          children: [
                                            Container(
                                              width: 44,
                                              height: 44,
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(12),
                                                color: isDark ? Ar.green.shade800 : Ar.green.shade50,
                                              ),
                                              child: Icon(
                                                Icons.admin_panel_settings_rounded,
                                                color: isDark ? Ar.green.shade300 : Ar.green,
                                                size: 22,
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.end,
                                                children: [
                                                  Text(
                                                    'ملاحظة للمدير',
                                                    style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight: FontWeight.w800,
                                                      color: isDark ? Ar.green.shade300 : Ar.green.shade800,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    'سيتم مراجعة طلب السلفة من قبل المدير التنفيذي قبل الموافقة عليه.',
                                                    style: TextStyle(
                                                      fontSize: 14,
                                                      fontWeight: FontWeight.w600,
                                                      color: isDark ? Ar.green.shade200 : Ar.green.shade700,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),

                                      // إرسال الآن
                                      Container(
                                        margin: const EdgeInsets.only(bottom: 30),
                                        decoration: BoxDecoration(
                                          borderRadius: BorderRadius.circular(20),
                                          boxShadow: [
                                            BoxShadow(
                                              color: primaryColor.withOpacity(0.4),
                                              blurRadius: 20,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: ElevatedButton(
                                          onPressed: _isSubmitting ? null : _submitAdvanceRequest,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: primaryColor,
                                            foregroundColor: Colors.white,
                                            minimumSize: const Size(double.infinity, 58),
                                            shape: RoundedRectangleBorder(
                                              borderRadius: BorderRadius.circular(20),
                                            ),
                                            elevation: 0,
                                          ),
                                          child: _isSubmitting
                                              ? Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                  strokeWidth: 2,
                                                  color: Colors.white,
                                                ),
                                              ),
                                              const SizedBox(width: 12),
                                              Text(
                                                'جاري الإرسال...',
                                                style: const TextStyle(
                                                  fontSize: 16,
                                                  fontWeight: FontWeight.w800,
                                                ),
                                              ),
                                            ],
                                          )
                                              : Row(
                                            mainAxisAlignment: MainAxisAlignment.center,
                                            children: [
                                              const Icon(Icons.send_rounded, size: 22),
                                              const SizedBox(width: 10),
                                              Text(
                                                'إرسال طلب السلفة',
                                                style: const TextStyle(
                                                  fontSize: 18,
                                                  fontWeight: FontWeight.w900,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                      ],
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      );
  }

  Widget _buildRequestTypeButton(bool isDark, Color textColor, Color subduedTextColor, Color primaryColor) {
    final icon = _requestTypeIcons[_requestType] ?? Icons.account_balance_wallet_rounded;
    final iconColor = _requestTypeColors[_requestType] ?? primaryColor;

    return GestureDetector(
      onTap: () => _openRequestTypeSheet(isDark),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: Glass.panel(isDark, r: 20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? iconColor.withOpacity(0.2) : iconColor.withOpacity(0.1),
              ),
              child: Icon(
                icon,
                color: iconColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'نوع الطلب *',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: subduedTextColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _requestType,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: primaryColor,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMonthButton(bool isDark, Color textColor, Color subduedTextColor, Color primaryColor) {
    return GestureDetector(
      onTap: () => _openMonthSheet(isDark),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: Glass.panel(isDark, r: 20),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isDark ? AppColors.primaryLight.withOpacity(0.2) : const Color(0xFFEDEAE5),
              ),
              child: Icon(
                Icons.calendar_month_rounded,
                color: primaryColor,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    'الشهر *',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: subduedTextColor,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _selectedMonth,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: textColor,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Icon(
              Icons.arrow_drop_down_rounded,
              color: primaryColor,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }

  void _openRequestTypeSheet(bool isDark) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        final appController = Provider.of<AppController>(context, listen: false);
        final isRTL = appController.isRTL;

        return Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Container(
            margin: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                color: isDark ? const Color(0xFF262624) : Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(
                          Icons.account_balance_wallet_rounded,
                          color: isDark ? AppColors.primaryLight : AppColors.primary,
                          size: 28,
                        ),
                        const Spacer(),
                        Text(
                          'اختر نوع الطلب',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(sheetContext),
                          child: Icon(
                            Icons.close_rounded,
                            color: isDark ? Colors.white70 : Ar.grey.shade600,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    ..._requestTypes.map((type) {
                      final icon = _requestTypeIcons[type] ?? Icons.account_balance_wallet_rounded;
                      final iconColor = _requestTypeColors[type] ?? Ar.grey;
                      final isSelected = type == _requestType;

                      return GestureDetector(
                        onTap: () {
                          setState(() {
                            _requestType = type;
                          });
                          Navigator.pop(sheetContext);
                        },
                        child: Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? (isDark ? iconColor.withOpacity(0.3) : iconColor.withOpacity(0.15))
                                : (isDark ? Colors.white.withOpacity(0.1) : Ar.grey.shade50),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: isSelected
                                  ? iconColor.withOpacity(0.5)
                                  : (isDark ? Colors.white.withOpacity(0.2) : Ar.grey.shade300),
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 44,
                                height: 44,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(12),
                                  color: isDark ? iconColor.withOpacity(0.2) : iconColor.withOpacity(0.1),
                                ),
                                child: Icon(
                                  icon,
                                  color: iconColor,
                                  size: 22,
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  type,
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                    color: isDark ? Colors.white : Colors.black87,
                                  ),
                                ),
                              ),
                              if (isSelected)
                                Icon(
                                  Icons.check_circle_rounded,
                                  color: iconColor,
                                  size: 24,
                                ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  void _openMonthSheet(bool isDark) {
    final appController = Provider.of<AppController>(context, listen: false);
    final isRTL = appController.isRTL;

    // تحويل اسم الشهر الحالي إلى رقم الشهر
    int currentMonthIndex = _months.indexOf(_selectedMonth);
    if (currentMonthIndex == -1) {
      currentMonthIndex = DateTime.now().month - 1;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) {
        return Directionality(
          textDirection: isRTL ? ui.TextDirection.rtl : ui.TextDirection.ltr,
          child: Container(
            margin: const EdgeInsets.all(16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(26),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 18),
                color: isDark ? const Color(0xFF262624) : Colors.white,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Icon(
                          Icons.calendar_month_rounded,
                          color: isDark ? AppColors.primaryLight : AppColors.primary,
                          size: 28,
                        ),
                        const Spacer(),
                        Text(
                          'اختر الشهر',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: isDark ? Colors.white : Colors.black87,
                          ),
                        ),
                        const Spacer(),
                        GestureDetector(
                          onTap: () => Navigator.pop(sheetContext),
                          child: Icon(
                            Icons.close_rounded,
                            color: isDark ? Colors.white70 : Ar.grey.shade600,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),

                    Container(
                      height: 260,
                      decoration: Glass.panel(isDark, r: 18),
                      child: ListView.builder(
                        itemCount: _months.length,
                        itemBuilder: (context, index) {
                          final month = _months[index];
                          final isSelected = month == _selectedMonth;

                          return GestureDetector(
                            onTap: () {
                              setState(() {
                                _selectedMonth = month;
                              });
                              Navigator.pop(sheetContext);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
                              decoration: BoxDecoration(
                                border: Border(
                                  bottom: index < _months.length - 1
                                      ? BorderSide(
                                    color: isDark
                                        ? Colors.white.withOpacity(0.1)
                                        : Ar.grey.shade200,
                                  )
                                      : BorderSide.none,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 44,
                                    height: 44,
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(12),
                                      color: isSelected
                                          ? (isDark
                                          ? AppColors.primaryLight.withOpacity(0.3)
                                          : AppColors.primary.withOpacity(0.15))
                                          : (isDark
                                          ? Colors.white.withOpacity(0.1)
                                          : Ar.grey.shade50),
                                    ),
                                    child: Icon(
                                      Icons.calendar_today_rounded,
                                      color: isSelected
                                          ? (isDark
                                          ? AppColors.primaryLight
                                          : AppColors.primary)
                                          : (isDark
                                          ? Colors.white70
                                          : Ar.grey.shade600),
                                      size: 22,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      month,
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: isSelected
                                            ? FontWeight.w900
                                            : FontWeight.w600,
                                        color: isSelected
                                            ? (isDark
                                            ? AppColors.primaryLight
                                            : AppColors.primary)
                                            : (isDark
                                            ? Colors.white
                                            : Colors.black87),
                                      ),
                                    ),
                                  ),
                                  if (isSelected)
                                    Icon(
                                      Icons.check_circle_rounded,
                                      color: isDark ? AppColors.primaryLight : AppColors.primary,
                                      size: 24,
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _pickImage() async {
    final XFile? image = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
      maxWidth: 1200,
    );

    if (image != null) {
      setState(() {
        _selectedImage = File(image.path);
      });
    }
  }

  Future<void> _submitAdvanceRequest() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_amount <= 0) {
      _showErrorDialog('يرجى إدخال مبلغ صحيح');
      return;
    }

    setState(() => _isSubmitting = true);

    try {
      String? imageBase64;
      if (_selectedImage != null) {
        final bytes = await _selectedImage!.readAsBytes();
        final base64Raw = base64Encode(bytes);
        imageBase64 = "data:image/jpeg;base64,$base64Raw";
      }

      final res = await AdvanceRequestApi.submitAdvanceRequestByManager(
        uid: widget.uid,
        employeeId: widget.uid, // always the person making the request
        requestType: _requestType,
        month: _selectedMonth,
        amount: _amount,
        note: _note,
        image: imageBase64,
      );

      if (!mounted) return;

      if (res["success"] == true) {
        _showSuccessDialog(res["message"] ?? 'تم إرسال الطلب ✅ — مستني موافقة المدير العام');

        _formKey.currentState!.reset();
        setState(() {
          _requestType = 'سلفة';
          _selectedMonth = _months[DateTime.now().month - 1];
          _amount = 0.0;
          _note = '';
          _selectedImage = null;
          _amountController.clear();
        });

        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && Navigator.canPop(context)) {
            Navigator.pop(context);
          }
        });
      } else {
        _showErrorDialog(res["message"] ?? 'حدث خطأ أثناء إرسال الطلب');
      }
    } catch (e) {
      _showErrorDialog('حدث خطأ أثناء إرسال الطلب: $e');
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
      }
    }
  }

  void _showErrorDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: const Color(0xFFE5604F),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
    );
  }

  void _showSuccessDialog(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle, color: Colors.white),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF2FA65A),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }
}