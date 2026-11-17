import 'package:flutter/widgets.dart' as w;
import 'package:flutter/widgets.dart' hide Text;

import '../pages/leads/leads_api.dart' show LeadsTr;
import '../pages/leads/leads_tr.dart' show leadsTranslations;
import 'ui_en.dart';

/// The whole app in the chosen language without touching every page:
///
/// Every file of the app shows text with this `Text` (each file imports Flutter's own `Text` hidden — see the
/// `hide Text` on its Flutter import). It is Flutter's Text with one step before it: in English (any language but
/// Arabic) the Arabic is put in English from [uiEn] — the app's and the server's Arabic sentences, each with its English.
///
///  1. the sentence as it is (`'تسجيل الخروج'` → `'Sign out'`);
///  2. a sentence with values in it (`'حاضر النهارده {0} من {1}'` → `'Present today {0} of {1}'`): the values stay;
///  3. else each Arabic piece of it on its own; what has no English stays as it is (names, the employees' own words).
///
/// Only what is shown changes: the values the pages keep, compare and send to the server stay Arabic.
class Text extends w.StatelessWidget {
  const Text(
    String this.data, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : textSpan = null;

  const Text.rich(
    InlineSpan this.textSpan, {
    super.key,
    this.style,
    this.strutStyle,
    this.textAlign,
    this.textDirection,
    this.locale,
    this.softWrap,
    this.overflow,
    this.textScaler,
    this.maxLines,
    this.semanticsLabel,
    this.textWidthBasis,
    this.textHeightBehavior,
    this.selectionColor,
  }) : data = null;

  final String? data;
  final InlineSpan? textSpan;
  final TextStyle? style;
  final StrutStyle? strutStyle;
  final TextAlign? textAlign;
  final TextDirection? textDirection;
  final Locale? locale;
  final bool? softWrap;
  final TextOverflow? overflow;
  final TextScaler? textScaler;
  final int? maxLines;
  final String? semanticsLabel;
  final TextWidthBasis? textWidthBasis;
  final TextHeightBehavior? textHeightBehavior;
  final Color? selectionColor;

  @override
  w.Widget build(w.BuildContext context) {
    // depends on the app's language: a const Text is built again when it changes
    final lang = w.Localizations.maybeLocaleOf(context)?.languageCode ?? LeadsTr.lang;
    if (data != null) {
      return w.Text(tx(data!, lang),
          style: style, strutStyle: strutStyle, textAlign: textAlign, textDirection: textDirection, locale: locale,
          softWrap: softWrap, overflow: overflow, textScaler: textScaler, maxLines: maxLines,
          semanticsLabel: semanticsLabel == null ? null : tx(semanticsLabel!, lang),
          textWidthBasis: textWidthBasis, textHeightBehavior: textHeightBehavior, selectionColor: selectionColor);
    }
    return w.Text.rich(_span(textSpan!, lang),
        style: style, strutStyle: strutStyle, textAlign: textAlign, textDirection: textDirection, locale: locale,
        softWrap: softWrap, overflow: overflow, textScaler: textScaler, maxLines: maxLines, semanticsLabel: semanticsLabel,
        textWidthBasis: textWidthBasis, textHeightBehavior: textHeightBehavior, selectionColor: selectionColor);
  }

  static InlineSpan _span(InlineSpan s, String lang) {
    if (lang == 'ar' || s is! TextSpan) return s;
    return TextSpan(
      text: s.text == null ? null : tx(s.text!, lang),
      style: s.style,
      recognizer: s.recognizer,
      mouseCursor: s.mouseCursor,
      onEnter: s.onEnter,
      onExit: s.onExit,
      semanticsLabel: s.semanticsLabel,
      locale: s.locale,
      spellOut: s.spellOut,
      children: s.children?.map((c) => _span(c, lang)).toList(),
    );
  }
}

final RegExp _arabic = RegExp('[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿]');
// an Arabic piece: Arabic words with the spaces / punctuation between them
final RegExp _run = RegExp(
    '[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿](?:[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿ «»"\'،؛؟!.,:\\-–—/()ـ]*[؀-ۿݐ-ݿﭐ-﷿ﹰ-﻿])?');
final Map<String, String> _cache = {};

class _Template {
  final String key;   // its longest fixed piece: a sentence that has it is tried
  final RegExp re;
  final String en;
  _Template(this.key, this.re, this.en);
}

List<_Template>? _templates;
List<_Template> _loadTemplates() {
  final out = <_Template>[];
  final hole = RegExp(r'\{(\d+)\}');
  uiEn.forEach((ar, en) {
    if (!ar.contains('{0}')) return;
    final fixed = ar.split(hole);
    var key = '';
    for (final f in fixed) {
      if (f.trim().length > key.length) key = f.trim();
    }
    if (key.isEmpty) return;
    final b = StringBuffer('^');
    var last = 0;
    for (final m in hole.allMatches(ar)) {
      b.write(RegExp.escape(ar.substring(last, m.start)));
      b.write('(.+?)');
      last = m.end;
    }
    b.write(RegExp.escape(ar.substring(last)));
    b.write(r'$');
    out.add(_Template(key, RegExp(b.toString(), dotAll: true), en));
  });
  out.sort((a, b) => b.key.length.compareTo(a.key.length));
  return out;
}

String? _exact(String s) => uiEn[s] ?? leadsTranslations[s]?[0];

/// [s] in the app's language (English for anything but Arabic). Arabic stays Arabic.
String tx(String s, [String? lang]) {
  final l = lang ?? LeadsTr.lang;
  if (l == 'ar' || s.isEmpty || !_arabic.hasMatch(s)) return s;
  final hit = _cache[s];
  if (hit != null) return hit;
  final r = _translate(s);
  if (_cache.length > 6000) _cache.clear();
  _cache[s] = r;
  return r;
}

/// [s] or null (an InputDecoration's label / hint …)
String? txn(String? s) => s == null ? null : tx(s);

String _translate(String s) {
  // 1) as it is (and without the spaces around it)
  final e = _exact(s);
  if (e != null) return e;
  final t = s.trim();
  if (t != s) {
    final e2 = _exact(t);
    if (e2 != null) return s.replaceFirst(t, e2);
  }
  // 2) a sentence with values in it
  for (final p in _templates ??= _loadTemplates()) {
    if (!t.contains(p.key)) continue;
    final m = p.re.firstMatch(t);
    if (m == null) continue;
    var out = p.en;
    for (var i = 1; i <= m.groupCount; i++) {
      final v = m.group(i) ?? '';
      out = out.replaceAll('{${i - 1}}', _exact(v.trim()) ?? v);
    }
    return s.replaceFirst(t, out);
  }
  // 3) each Arabic piece on its own
  return s.replaceAllMapped(_run, (m) => _exact(m.group(0)!) ?? m.group(0)!);
}

/// [s] in the app's language, keeping its type (String stays String, String? stays String?) — for the texts Flutter
/// draws itself: an InputDecoration's label / hint / helper / error, a tooltip, a Tab's text.
T txs<T extends String?>(T s) => (s == null ? null : tx(s)) as T;
