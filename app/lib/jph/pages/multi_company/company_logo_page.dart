import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../services/app_controller.dart';
import '../../widgets/app_background.dart';
import '../../widgets/doc_logos.dart';
import '../../widgets/glass_ui.dart';
import '../../widgets/jph_form_ui.dart';

/// إعدادات الشركة ← لوجو الشركة: the logo printed on every document of the company (payment vouchers, payslips …).
class CompanyLogoPage extends StatefulWidget {
  const CompanyLogoPage({super.key});

  @override
  State<CompanyLogoPage> createState() => _CompanyLogoPageState();
}

class _CompanyLogoPageState extends State<CompanyLogoPage> {
  late Future<Uint8List?> _logo = DocLogos.company();

  Future<void> _change() async {
    final img = await DocLogos.pick(context);
    if (img == null || !mounted) return;
    if (await DocLogos.upload(context, '/company/logo', img, ok: 'اتحفظ لوجو الشركة ✅')) setState(() => _logo = DocLogos.company());
  }

  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<AppController>().isDark;
    return AppBackground(
      child: Directionality(
        textDirection: ui.TextDirection.rtl,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: SafeArea(
            child: Column(children: [
              JphUi.header(context, isDark: isDark, isRTL: true, title: 'لوجو الشركة'),
              Expanded(
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 100), children: [
                  Container(
                    padding: const EdgeInsets.all(18),
                    decoration: Glass.panel(isDark, r: 20),
                    child: Column(children: [
                      FutureBuilder<Uint8List?>(
                        future: _logo,
                        builder: (_, s) => Container(
                          height: 180,
                          alignment: Alignment.center,
                          decoration: Glass.tile(isDark, r: 16),
                          child: s.connectionState != ConnectionState.done
                              ? const CircularProgressIndicator()
                              : s.data == null
                                  ? Text('مفيش لوجو لسه — المستندات بتطلع باللوجو الأساسي', textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark)))
                                  : Padding(padding: const EdgeInsets.all(12), child: Image.memory(s.data!, fit: BoxFit.contain)),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text('اللوجو ده بيطلع على أي مستند يخص الشركة: إيصالات الصرف والدفع وبيان الراتب للموظفين.',
                          textAlign: TextAlign.center, style: TextStyle(color: JphUi.sub(isDark))),
                      const SizedBox(height: 14),
                      SizedBox(
                        width: double.infinity,
                        height: 46,
                        child: FilledButton.icon(onPressed: _change, icon: const Icon(Icons.upload_rounded), label: const Text('اختار لوجو الشركة')),
                      ),
                    ]),
                  ),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}
