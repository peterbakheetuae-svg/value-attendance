import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart' hide Text;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../l10n/tx_text.dart';
import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/app_nav.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';
import '../leads/leads_api.dart' show LeadsTr;

/// «سياسة الدعم» → الأسئلة الشائعة · دليل المستخدم · استكشاف الأخطاء · الإبلاغ عن مشكلة.
/// The content is written in Arabic and English here (Hindi / Urdu read the English).
const supportEmail = 'VALUNIVO@gmail.com';

String _l(String ar, String en) => LeadsTr.lang == 'ar' ? ar : en;

/// one help topic: a title and its paragraphs / steps
class HelpItem {
  final String ar, en;
  final List<(String, String)> lines;
  final IconData icon;
  const HelpItem(this.ar, this.en, this.lines, {this.icon = Icons.help_outline_rounded});
}

/// the page frame every help page uses: the app background, a back button and a title
class _HelpScaffold extends StatelessWidget {
  final String title;
  final Widget child;
  const _HelpScaffold({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppController>();
    final d = app.isDark;
    return Directionality(
      textDirection: LeadsTr.rtl ? TextDirection.rtl : TextDirection.ltr,
      child: AppBackground(
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(children: [
                  IconButton(icon: Icon(Icons.arrow_back, color: Glass.ink(d)), onPressed: () => Navigator.pop(context)),
                  const SizedBox(width: 6),
                  Expanded(child: Text(title, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Glass.ink(d)))),
                ]),
              ),
              Expanded(
                child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: child)),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// a searchable list of expandable topics (FAQ, user guide, troubleshooting)
class _TopicsPage extends StatefulWidget {
  final String titleAr, titleEn, introAr, introEn;
  final List<HelpItem> items;
  final bool numbered;
  const _TopicsPage({required this.titleAr, required this.titleEn, required this.introAr, required this.introEn, required this.items,
      this.numbered = false});

  @override
  State<_TopicsPage> createState() => _TopicsPageState();
}

class _TopicsPageState extends State<_TopicsPage> {
  final _q = TextEditingController();

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppController>().isDark;
    final q = _q.text.trim().toLowerCase();
    final shown = widget.items.where((i) {
      if (q.isEmpty) return true;
      final all = [i.ar, i.en, for (final l in i.lines) ...[l.$1, l.$2]].join(' ').toLowerCase();
      return all.contains(q);
    }).toList();
    return _HelpScaffold(
      title: _l(widget.titleAr, widget.titleEn),
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        Text(_l(widget.introAr, widget.introEn), style: TextStyle(fontSize: 14, height: 1.6, color: Glass.muted(d))),
        const SizedBox(height: 12),
        Container(
          height: 46,
          decoration: Glass.tile(d, r: 99),
          child: TextField(
            controller: _q,
            onChanged: (_) => setState(() {}),
            style: TextStyle(fontSize: 15, color: Glass.ink(d)),
            decoration: InputDecoration(
              border: InputBorder.none,
              hintText: _l('دوّر في المواضيع', 'Search the topics'),
              hintStyle: TextStyle(color: Glass.muted(d)),
              prefixIcon: Icon(Icons.search_rounded, color: Glass.muted(d)),
              contentPadding: const EdgeInsets.symmetric(vertical: 13),
            ),
          ),
        ),
        const SizedBox(height: 12),
        if (shown.isEmpty)
          Padding(
            padding: const EdgeInsets.all(28),
            child: Text(_l('مفيش موضوع بالبحث ده — جرّب «الإبلاغ عن مشكلة»', 'No topic matches — try "Report an issue"'),
                textAlign: TextAlign.center, style: TextStyle(color: Glass.muted(d))),
          ),
        for (final i in shown)
          Container(
            margin: const EdgeInsets.only(bottom: 10),
            decoration: Glass.panel(d, r: 16),
            clipBehavior: Clip.antiAlias,
            child: Theme(
              data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                initiallyExpanded: q.isNotEmpty && shown.length <= 3,
                leading: Icon(i.icon, color: Glass.blue),
                title: Text(_l(i.ar, i.en), style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Glass.ink(d))),
                childrenPadding: const EdgeInsetsDirectional.fromSTEB(18, 0, 18, 14),
                expandedCrossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var n = 0; n < i.lines.length; n++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (widget.numbered || i.lines.length > 1)
                          Container(
                            width: 22,
                            height: 22,
                            margin: const EdgeInsetsDirectional.only(end: 10, top: 1),
                            alignment: Alignment.center,
                            decoration: BoxDecoration(color: Glass.blue.withOpacity(0.15), shape: BoxShape.circle),
                            child: Text('${n + 1}', style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: Glass.blue)),
                          ),
                        Expanded(
                          child: Text(_l(i.lines[n].$1, i.lines[n].$2),
                              style: TextStyle(fontSize: 14, height: 1.6, color: Glass.ink(d))),
                        ),
                      ]),
                    ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 8),
        _StillNeedHelp(isDark: d),
      ]),
    );
  }
}

class _StillNeedHelp extends StatelessWidget {
  final bool isDark;
  const _StillNeedHelp({required this.isDark});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: Glass.panel(isDark, r: 16),
        child: Row(children: [
          const Icon(Icons.support_agent_rounded, color: Glass.blue, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Text(_l('لسه محتاج مساعدة؟ ابعت لنا المشكلة وهنرد عليك.', 'Still need help? Send us the issue and we will get back to you.'),
                style: TextStyle(fontSize: 13.5, color: Glass.ink(isDark))),
          ),
          TextButton(
            onPressed: () => Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const ReportIssuePage())),
            child: Text(_l('الإبلاغ عن مشكلة', 'Report an issue')),
          ),
        ]),
      );
}

// ==================================================================== الأسئلة الشائعة
class FaqPage extends StatelessWidget {
  const FaqPage({super.key});
  @override
  Widget build(BuildContext context) => const _TopicsPage(
        titleAr: 'الأسئلة الشائعة',
        titleEn: 'Frequently asked questions',
        introAr: 'إجابات سريعة لأكتر الأسئلة اللي بتوصلنا عن تطبيق VALUNIVO.',
        introEn: 'Quick answers to the questions we are asked most about VALUNIVO.',
        items: _faq,
      );
}

const _faq = <HelpItem>[
  HelpItem('إزاي أسجّل دخول أول مرة؟', 'How do I sign in for the first time?', [
    ('اكتب كود الموظف أو الموبايل أو الإيميل، وكلمة المرور المؤقتة اللي اداهالك الموارد البشرية.',
        'Enter your employee code, mobile or email, and the temporary password HR gave you.'),
    ('التطبيق هيطلب منك تغيّر كلمة المرور على طول — اختار كلمة 8 حروف على الأقل فيها حروف وأرقام.',
        'The app asks you to change the password right away — choose at least 8 characters with letters and digits.'),
  ], icon: Icons.login_rounded),
  HelpItem('نسيت كلمة المرور، أعمل إيه؟', 'I forgot my password. What do I do?', [
    ('من شاشة الدخول اضغط «نسيت كلمة المرور» واكتب إيميلك المتسجل — هيوصلك كود من 6 أرقام.',
        'On the sign-in screen tap "Forgot password" and enter your registered email — a 6-digit code arrives.'),
    ('في حد أقصى للأكواد (3 كل ربع ساعة) — لو وصلت له استنى الوقت اللي ظاهر أو كلّم الموارد البشرية.',
        'Codes are limited (3 per quarter hour) — if you reach the limit, wait for the time shown or contact HR.'),
  ], icon: Icons.lock_reset_rounded),
  HelpItem('ليه البصمة مش بتسجّل حضوري؟', 'Why won\'t check-in work?', [
    ('لازم تكون جوه نطاق المكتب والـ GPS شغال، والوقت داخل مواعيد شغلك.',
        'You must be inside the office area with GPS on, and within your working hours.'),
    ('لو الشركة مفعّلة الصورة، لازم الكاميرا تكون متاحة للتطبيق.',
        'If the company requires a selfie, the camera must be allowed for the app.'),
    ('شوف «استكشاف الأخطاء» لو المشكلة فضلت.', 'See "Troubleshooting" if the problem stays.'),
  ], icon: Icons.fingerprint_rounded),
  HelpItem('ينفع أسجّل حضور من غير نت؟', 'Can I check in without internet?', [
    ('أيوه — الحركة بتتحفظ على الموبايل وتتبعت أول ما النت يرجع، بنفس الوقت اللي سجّلت فيه.',
        'Yes — the punch is saved on the phone and sent as soon as the internet is back, with the time you recorded it.'),
    ('الحركة اللي بتوصل ليوم فات بتحتاج مراجعة الموارد البشرية.', 'A punch arriving for a past day needs HR review.'),
  ], icon: Icons.wifi_off_rounded),
  HelpItem('إزاي أطلب إجازة أو إذن؟', 'How do I request leave or a permission?', [
    ('من الصفحة الرئيسية اختار «إجازة» أو من «الطلبات»، حدد النوع والتاريخ والسبب وابعت.',
        'From the home page choose "Leave" or go to "Requests", pick the type, date and reason, and send.'),
    ('الطلب بيروح لمديرك وبعدين للموارد البشرية، وبيوصلك إشعار بالقرار.',
        'The request goes to your manager then to HR, and you are notified of the decision.'),
  ], icon: Icons.event_available_rounded),
  HelpItem('إزاي أطلب سلفة؟', 'How do I request an advance?', [
    ('من «السلف» اكتب المبلغ والسبب وعدد شهور الخصم. بعد الموافقة بيتم الصرف بكود تأكيد بيظهرلك على التطبيق.',
        'From "Advances" enter the amount, reason and number of deduction months. After approval it is paid with a confirmation code shown in your app.'),
  ], icon: Icons.payments_rounded),
  HelpItem('إيه كود الاستلام اللي بيظهرلي؟', 'What is the receipt code I see?', [
    ('لما حد بيصرفلك فلوس (مرتب، عمولة، سلفة)، التطبيق بيظهرلك كود من 4 أرقام. قوله للي بيصرفلك بس، وهو يكتبه عشان الصرف يتأكد.',
        'When someone pays you (salary, commission, advance), the app shows a 4-digit code. Tell it only to the person paying you; he enters it to confirm the payment.'),
    ('متديش الكود لحد تاني.', 'Never give the code to anyone else.'),
  ], icon: Icons.pin_rounded),
  HelpItem('ليه مش شايف ليد جديد اتوزع عليا؟', 'Why don\'t I see a lead assigned to me?', [
    ('الليدز الجديدة بتظهر أول الصفحة الرئيسية وفي «لوحة السيلز» → «جديد». اسحب الصفحة لتحت عشان تتحدث.',
        'New leads show at the top of the home page and in "Sales board" → "New". Pull down to refresh.'),
    ('اتأكد إن الإشعارات مفعّلة للتطبيق.', 'Make sure notifications are enabled for the app.'),
  ], icon: Icons.person_add_alt_1_rounded),
  HelpItem('إزاي أعرض عقار لإعادة البيع أو الإيجار؟', 'How do I list a property for resale or rent?', [
    ('من «المشاريع» → «تسويق» → «إعادة بيع» أو «إيجار» اضغط «إضافة عقار».',
        'From "Projects" → "Marketing" → "Resale" or "Rental" tap "Add property".'),
    ('ضيف الصور والنوع والعنوان والمساحة والسعر والتشطيب والوصف واحفظ.',
        'Add the photos, type, address, area, price, finishing and description, then save.'),
    ('أي حد يقدر يبيعه: «بيع العقار» ويكتب العميل والسعر النهائي والعمولة، والمسؤول الإداري بيستلم العمولة ويقسمها.',
        'Anyone can sell it: "Sell the property" with the client, final price and commission; the administrative officer receives and splits the commission.'),
  ], icon: Icons.home_work_rounded),
  HelpItem('إزاي أغيّر اللغة أو الوضع الليلي؟', 'How do I change the language or dark mode?', [
    ('من «الإعدادات» اختار اللغة (عربي / English / हिन्दी / اردو) وفعّل أو اقفل الوضع المظلم.',
        'In "Settings" choose the language (Arabic / English / Hindi / Urdu) and switch dark mode on or off.'),
  ], icon: Icons.translate_rounded),
  HelpItem('هل بياناتي ومكاني بيتشافوا طول الوقت؟', 'Is my location watched all the time?', [
    ('المتابعة بتشتغل بس من تسجيل الحضور لحد الانصراف، ولو الشركة مفعّلاها لموظفك. بعد الانصراف بتقف لوحدها.',
        'Tracking runs only from check-in to check-out, and only if the company enabled it for you. It stops by itself after check-out.'),
    ('تفاصيل أكتر في «سياسة الخصوصية».', 'More in the "Privacy policy".'),
  ], icon: Icons.privacy_tip_rounded),
  HelpItem('التطبيق بيتحدث إزاي؟', 'How does the app update?', [
    ('على أندرويد والكمبيوتر التطبيق بيقولك لما يكون فيه تحديث جديد — وافق عليه وهو بيتنزل ويتثبت.',
        'On Android and the computer the app tells you when an update is available — accept it and it downloads and installs.'),
    ('على المتصفح افتح الصفحة تاني عشان تاخد آخر نسخة.', 'In the browser, reload the page to get the latest version.'),
  ], icon: Icons.system_update_rounded),
];

// ==================================================================== دليل المستخدم
class UserGuidePage extends StatelessWidget {
  const UserGuidePage({super.key});
  @override
  Widget build(BuildContext context) => const _TopicsPage(
        titleAr: 'دليل المستخدم',
        titleEn: 'User guide',
        introAr: 'شرح خطوة بخطوة لأهم أجزاء التطبيق. اللي بيظهرلك بيعتمد على صلاحيات وظيفتك.',
        introEn: 'A step-by-step guide to the main parts of the app. What you see depends on your job\'s permissions.',
        numbered: true,
        items: _guide,
      );
}

const _guide = <HelpItem>[
  HelpItem('الحضور والانصراف', 'Check-in and check-out', [
    ('افتح التطبيق وأنت في المكتب، واضغط على زرار البصمة في الصفحة الرئيسية.', 'Open the app at the office and tap the fingerprint button on the home page.'),
    ('أكّد بالبصمة أو الوجه، وصوّر سيلفي لو الشركة طالبة كده.', 'Confirm with your fingerprint or face, and take a selfie if the company requires it.'),
    ('في آخر اليوم اضغط نفس الزرار للانصراف.', 'At the end of the day tap the same button to check out.'),
    ('للبريك أو الخروج بإذن أو المعاينة استخدم التبويب المناسب فوق الزرار.', 'For a break, a leave permission or a viewing use the matching tab above the button.'),
  ], icon: Icons.fingerprint_rounded),
  HelpItem('الطلبات والإجازات', 'Requests and leave', [
    ('من «الطلبات» اختار نوع الطلب: إجازة يوم كامل، إذن ساعات، أو مأمورية.', 'In "Requests" choose the type: full-day leave, hourly permission or mission.'),
    ('حدد التاريخ والمدة واكتب السبب.', 'Set the date and duration and write the reason.'),
    ('تابع حالة الطلب من نفس الصفحة — بيوصلك إشعار بالموافقة أو الرفض.', 'Follow the request\'s status on the same page — you are notified of approval or rejection.'),
  ], icon: Icons.event_note_rounded),
  HelpItem('السلف والصرف', 'Advances and payments', [
    ('اطلب السلفة من «السلف» بالمبلغ وعدد شهور الخصم.', 'Request an advance from "Advances" with the amount and deduction months.'),
    ('بعد الموافقة، وقت الصرف هيظهرلك كود من 4 أرقام — قوله للي بيصرفلك.', 'After approval, at payment time a 4-digit code appears — tell it to whoever pays you.'),
    ('الأقساط بتتخصم من مرتبك أوتوماتيك كل شهر.', 'Installments are deducted from your salary automatically each month.'),
  ], icon: Icons.account_balance_wallet_rounded),
  HelpItem('لوحة السيلز والليدز', 'Sales board and leads', [
    ('الليد الجديد بيظهرلك أول الصفحة الرئيسية — اضغط عليه عشان تفتحه.', 'A new lead appears at the top of the home page — tap it to open it.'),
    ('كلّم العميل أو ابعتله واتساب من صفحة الليد، وبعدها سجّل أكشن: المرحلة والتعليق ومعاد المتابعة الجاية.', 'Call the client or WhatsApp him from the lead page, then record an action: the stage, a comment and the next follow-up date.'),
    ('«المهام» و«التقويم» بيفكروك بالمتابعات، والمتأخر بيظهر في «Delay List».', '"Tasks" and "Calendar" remind you of follow-ups; overdue ones show in the "Delay List".'),
    ('لو العميل حجز، حوّله لحجز وحدة من صفحة الليد.', 'If the client reserves, turn it into a unit reservation from the lead page.'),
  ], icon: Icons.groups_rounded),
  HelpItem('المشاريع والوحدات', 'Projects and units', [
    ('من «المشاريع» اختار المشروع عشان تشوف وحداته وحالتها (فاضية / محجوزة / متعاقد عليها).', 'In "Projects" open a project to see its units and their status (free / reserved / contracted).'),
    ('«طباعة عرض سعر» بتعمل عرض سعر للوحدة بخطة سداد تقدر تعدّلها.', '"Print a price quote" makes a unit quote with a payment plan you can edit.'),
    ('الإدارة تقدر تضيف وحدات المشروع كلها مرة واحدة من شيت إكسيل («استيراد وحدات من إكسيل»).', 'The administration can add all of a project\'s units at once from an Excel sheet ("Import units from Excel").'),
  ], icon: Icons.apartment_rounded),
  HelpItem('إعادة البيع والإيجار', 'Resale and rental', [
    ('«إضافة عقار»: صور، نوع، عنوان، مساحة، سعر، تشطيب ووصف.', '"Add property": photos, type, address, area, price, finishing and description.'),
    ('«بيع العقار» أو «تأجير العقار»: اسم العميل وتليفونه والسعر النهائي والعمولة.', '"Sell" or "Rent out the property": the client\'s name and phone, the final price and the commission.'),
    ('المسؤول الإداري بيوصله إشعار، يستلم العمولة ويقسمها: البائع، صاحب العرض، مدير المبيعات، والباقي للمكتب.', 'The administrative officer is notified, receives the commission and splits it: seller, lister, sales manager, and the rest to the office.'),
  ], icon: Icons.real_estate_agent_rounded),
  HelpItem('الخزنة والمصروفات (للإدارة)', 'Cashbox and expenses (administration)', [
    ('سجّل التحصيلات والمصروفات من «الخزنة» مع طريقة الدفع والإيصال.', 'Record collections and expenses in "Cashbox" with the payment method and receipt.'),
    ('الصرف للموظفين بيتأكد بالكود اللي بيظهر عندهم.', 'Payments to employees are confirmed with the code shown in their app.'),
    ('التقارير والفلتر اللي فوق بيطبّق على كل التبويبات.', 'The reports and the top filter apply to all tabs.'),
  ], icon: Icons.point_of_sale_rounded),
  HelpItem('الإعدادات والحساب', 'Settings and account', [
    ('من «الإعدادات» غيّر اللغة والوضع المظلم وكلمة المرور.', 'In "Settings" change the language, dark mode and password.'),
    ('من «الملف الشخصي» شوف بياناتك وكارت الموظف.', 'In "Profile" see your details and employee card.'),
    ('«تسجيل الخروج» بيمسح بياناتك من الجهاز.', '"Sign out" clears your data from the device.'),
  ], icon: Icons.settings_rounded),
];

// ==================================================================== استكشاف الأخطاء
class TroubleshootingPage extends StatelessWidget {
  const TroubleshootingPage({super.key});
  @override
  Widget build(BuildContext context) => const _TopicsPage(
        titleAr: 'استكشاف الأخطاء',
        titleEn: 'Troubleshooting',
        introAr: 'جرّب الخطوات دي بالترتيب قبل ما تبعت المشكلة — أغلب المشاكل بتتحل منها.',
        introEn: 'Try these steps in order before reporting — most problems are solved by them.',
        numbered: true,
        items: _trouble,
      );
}

const _trouble = <HelpItem>[
  HelpItem('«إنت بعيد عن المكتب» أو الموقع مش مضبوط', '"You are away from the office" or a wrong location', [
    ('شغّل الـ GPS واختار «دقة عالية» في إعدادات الموقع.', 'Turn GPS on and choose "High accuracy" in the location settings.'),
    ('اسمح للتطبيق بالموقع «أثناء الاستخدام» على الأقل.', 'Allow the app location access, at least "While using the app".'),
    ('اطلع جنب شباك أو برّه المبنى ثواني لحد ما الموقع يتظبط وجرّب تاني.', 'Step near a window or outside for a few seconds until the location settles, then retry.'),
    ('اقفل أي برنامج بيغيّر الموقع — التطبيق بيكتشفه ويبلّغ الإدارة.', 'Close any location-changing app — the app detects it and reports it to the administration.'),
  ], icon: Icons.location_off_rounded),
  HelpItem('الكاميرا مش بتفتح للسيلفي', 'The camera won\'t open for the selfie', [
    ('اسمح للتطبيق بالكاميرا من إعدادات الموبايل → التطبيقات → VALUNIVO → الأذونات.', 'Allow the camera: phone Settings → Apps → VALUNIVO → Permissions.'),
    ('اقفل أي تطبيق تاني بيستخدم الكاميرا.', 'Close any other app using the camera.'),
    ('اقفل التطبيق خالص وافتحه تاني.', 'Close the app completely and open it again.'),
  ], icon: Icons.no_photography_rounded),
  HelpItem('الإشعارات مش بتوصل', 'Notifications don\'t arrive', [
    ('فعّل إشعارات VALUNIVO من إعدادات الموبايل.', 'Enable VALUNIVO notifications in the phone settings.'),
    ('اقفل «توفير البطارية» للتطبيق أو خليه «غير مقيّد».', 'Turn off battery saving for the app or set it to "Unrestricted".'),
    ('سجّل خروج ودخول تاني عشان الجهاز يتسجل من جديد.', 'Sign out and in again so the device registers again.'),
  ], icon: Icons.notifications_off_rounded),
  HelpItem('كود الإيميل (OTP) مش واصل', 'The email code (OTP) doesn\'t arrive', [
    ('شوف فولدر Spam أو «الرسائل غير المرغوب فيها».', 'Check the Spam / Junk folder.'),
    ('اتأكد إن الإيميل المتسجل في حسابك صح — الموارد البشرية تقدر تراجعه.', 'Make sure your account\'s email is right — HR can check it.'),
    ('في حد أقصى للأكواد: لو ظهرلك «وصلت للحد المسموح به» استنى الوقت المكتوب.', 'Codes are limited: if you see "Limit reached", wait for the time shown.'),
  ], icon: Icons.mark_email_unread_rounded),
  HelpItem('الحساب اتقفل أو كلمة المرور غلط', 'Account locked or wrong password', [
    ('بعد 5 محاولات غلط الدخول بيتقفل 15 دقيقة — استنى وجرّب تاني.', 'After 5 wrong attempts sign-in locks for 15 minutes — wait and retry.'),
    ('استخدم «نسيت كلمة المرور» أو اطلب من الموارد البشرية إعادة تعيينها.', 'Use "Forgot password" or ask HR to reset it.'),
  ], icon: Icons.lock_rounded),
  HelpItem('التطبيق بطيء أو «مش قادر أحمّل البيانات»', 'The app is slow or "Couldn\'t load the data"', [
    ('اتأكد من النت (واي فاي أو بيانات) وجرّب «حاول تاني».', 'Check your internet (Wi-Fi or data) and tap "Try again".'),
    ('أول فتحة الصبح ممكن تاخد ثواني زيادة لحد ما السيرفر يصحى.', 'The first opening in the morning can take a few extra seconds while the server wakes up.'),
    ('اسحب الصفحة لتحت عشان تتحدث.', 'Pull the page down to refresh.'),
  ], icon: Icons.cloud_off_rounded),
  HelpItem('التحديث مش بيتثبت', 'The update won\'t install', [
    ('على أندرويد اسمح بـ «تثبيت تطبيقات من مصادر غير معروفة» لـ VALUNIVO لما يطلب.', 'On Android allow "Install unknown apps" for VALUNIVO when asked.'),
    ('اتأكد إن فيه مساحة كفاية على الموبايل.', 'Make sure the phone has enough free space.'),
    ('لو فضلت المشكلة نزّل آخر نسخة من jaurea.com/valunivo.', 'If it persists, download the latest version from jaurea.com/valunivo.'),
  ], icon: Icons.system_update_alt_rounded),
  HelpItem('حركة سجّلتها مش ظاهرة', 'A punch I recorded isn\'t showing', [
    ('لو كنت من غير نت، الحركة بتتبعت أول ما النت يرجع — افتح التطبيق وانت متصل.', 'If you were offline, the punch is sent once you are back online — open the app while connected.'),
    ('متسجلش خروج قبل ما الحركات المحفوظة تتبعت.', 'Don\'t sign out before the saved punches are sent.'),
    ('الحركة اللي وصلت ليوم فات بتحتاج مراجعة الموارد البشرية.', 'A punch that arrived for a past day needs HR review.'),
  ], icon: Icons.sync_problem_rounded),
];

// ==================================================================== الإبلاغ عن مشكلة
class ReportIssuePage extends StatefulWidget {
  const ReportIssuePage({super.key});
  @override
  State<ReportIssuePage> createState() => _ReportIssuePageState();
}

class _ReportIssuePageState extends State<ReportIssuePage> {
  static const _kinds = [
    ('login', 'الدخول وكلمة المرور', 'Sign-in and password', Icons.lock_rounded),
    ('attendance', 'الحضور والانصراف', 'Check-in and check-out', Icons.fingerprint_rounded),
    ('requests', 'الطلبات والإجازات', 'Requests and leave', Icons.event_note_rounded),
    ('money', 'المرتبات والصرف', 'Salaries and payments', Icons.payments_rounded),
    ('leads', 'الليدز والمشاريع', 'Leads and projects', Icons.groups_rounded),
    ('notifications', 'الإشعارات', 'Notifications', Icons.notifications_rounded),
    ('other', 'حاجة تانية', 'Something else', Icons.more_horiz_rounded),
  ];
  String _kind = 'attendance';
  final _where = TextEditingController(), _what = TextEditingController();
  String _device = '';

  @override
  void initState() {
    super.initState();
    _info();
  }

  @override
  void dispose() {
    _where.dispose();
    _what.dispose();
    super.dispose();
  }

  Future<void> _info() async {
    var v = '';
    try {
      final p = await PackageInfo.fromPlatform();
      v = '${p.version}+${p.buildNumber}';
    } catch (_) {}
    final os = kIsWeb ? 'Web' : switch (defaultTargetPlatform) {
          TargetPlatform.android => 'Android',
          TargetPlatform.iOS => 'iOS',
          TargetPlatform.windows => 'Windows',
          TargetPlatform.macOS => 'macOS',
          _ => 'Linux',
        };
    if (mounted) setState(() => _device = 'VALUNIVO $v · $os');
  }

  String get _kindLabel => _kinds.firstWhere((k) => k.$1 == _kind).$2;

  String _body() => [
        'نوع المشكلة: $_kindLabel',
        if (_where.text.trim().isNotEmpty) 'الصفحة: ${_where.text.trim()}',
        '',
        'الوصف:',
        _what.text.trim(),
        '',
        '—',
        'الموظف: ${AppNav.name ?? ''} (${AppNav.uid ?? ''})',
        'الجهاز: $_device',
        'الوقت: ${DateTime.now().toLocal().toString().substring(0, 16)}',
      ].join('\n');

  Future<void> _send() async {
    if (_what.text.trim().length < 10) {
      JphUi.toast(context, {'success': false, 'message': _l('اكتب وصف المشكلة (10 حروف على الأقل)', 'Describe the issue (at least 10 characters)')});
      return;
    }
    final uri = Uri(scheme: 'mailto', path: supportEmail, query: _query({
      'subject': 'VALUNIVO — مشكلة: $_kindLabel',
      'body': _body(),
    }));
    var opened = false;
    try {
      opened = await launchUrl(uri);
    } catch (_) {}
    if (!mounted) return;
    if (!opened) {
      await Clipboard.setData(ClipboardData(text: _body()));
      if (!mounted) return;
      JphUi.toast(context, {
        'success': true,
        'message': _l('مفيش برنامج إيميل — اتنسخ نص المشكلة، ابعته لـ $supportEmail', 'No email app — the report was copied; send it to $supportEmail'),
      });
    }
  }

  static String _query(Map<String, String> p) =>
      p.entries.map((e) => '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}').join('&');

  @override
  Widget build(BuildContext context) {
    final d = context.watch<AppController>().isDark;
    return _HelpScaffold(
      title: _l('الإبلاغ عن مشكلة', 'Report an issue'),
      child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 40), children: [
        Text(_l('قولنا حصل إيه بالظبط، وهنرد عليك على إيميلك في أقرب وقت. بيانات جهازك ونسخة التطبيق بتتضاف لوحدها عشان نوصل للمشكلة أسرع.',
                'Tell us exactly what happened and we will reply to your email as soon as possible. Your device and app version are added automatically so we reach the problem faster.'),
            style: TextStyle(fontSize: 14, height: 1.6, color: Glass.muted(d))),
        const SizedBox(height: 14),
        Text(_l('نوع المشكلة', 'Issue type'), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Glass.ink(d))),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final k in _kinds)
            ChoiceChip(
              avatar: Icon(k.$4, size: 18),
              label: Text(_l(k.$2, k.$3)),
              selected: _kind == k.$1,
              onSelected: (_) => setState(() => _kind = k.$1),
            ),
        ]),
        const SizedBox(height: 14),
        JphUi.input(isDark: d, label: _l('الصفحة اللي فيها المشكلة (اختياري)', 'The page with the problem (optional)'), controller: _where,
            icon: Icons.web_asset_rounded, big: false),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: JphUi.box(d),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(_l('اوصف المشكلة *', 'Describe the problem *'),
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: JphUi.sub(d))),
            TextField(
              controller: _what,
              minLines: 5,
              maxLines: 12,
              maxLength: 2000,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: _l('عملت إيه، وكان المفروض يحصل إيه، وحصل إيه بدل كده…', 'What you did, what should have happened, and what happened instead…'),
                hintStyle: TextStyle(color: JphUi.sub(d), fontSize: 13.5),
              ),
              style: TextStyle(fontSize: 14.5, height: 1.5, color: JphUi.text(d)),
            ),
          ]),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: Glass.tile(d, r: 14),
          child: Row(children: [
            Icon(Icons.phone_android_rounded, color: Glass.muted(d), size: 20),
            const SizedBox(width: 10),
            Expanded(child: Text(_device.isEmpty ? '…' : _device, style: TextStyle(fontSize: 12.5, color: Glass.muted(d)))),
          ]),
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 50,
          child: ElevatedButton.icon(
            onPressed: _send,
            icon: const Icon(Icons.send_rounded),
            label: Text(_l('ابعت المشكلة', 'Send the report'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Glass.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: supportEmail));
              if (context.mounted) JphUi.toast(context, {'success': true, 'message': _l('اتنسخ الإيميل', 'Email copied')});
            },
            icon: const Icon(Icons.copy_rounded, size: 18),
            label: const Text(supportEmail),
          ),
        ),
      ]),
    );
  }
}
