import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/api_service.dart';
import 'jph_form_ui.dart';

/// The logos printed on documents: the company's (payment vouchers, payslips …) and a development company's
/// (its reservation forms). Fetched once and kept for the session; replaced when a new one is uploaded.
class DocLogos {
  DocLogos._();
  static final Map<String, Future<Uint8List?>> _cache = {};

  static Future<Uint8List?> _load(String key, String path) => _cache.putIfAbsent(key, () async {
        final r = await ApiService.post({'action': 'cash_get', 'path': path});
        final s = '${r['image'] ?? ''}';
        final i = s.indexOf(',');
        return i < 0 ? null : base64Decode(s.substring(i + 1));
      });

  /// the company's own logo (null when none is set — the documents keep their built-in one)
  static Future<Uint8List?> company() => _load('company', '/company/logo');

  /// a development company's logo / picture
  static Future<Uint8List?> developer(String id, {String kind = 'logo', Object? at}) =>
      _load('dev:$id:$kind:$at', '/exclusive/developers/$id/image/$kind');

  /// the company's name for its documents (company settings), else the built-in one
  static Future<String>? _name;
  static Future<String> companyName() => _name ??= () async {
        final r = await ApiService.post({'action': 'get_settings'});
        final st = ((r['settings'] as Map?) ?? const {});
        final n = '${st['company_name_ar'] ?? ''}'.trim();
        return n.isEmpty ? 'فاليو جروب للتطوير العقاري' : n;
      }();

  static void forget(String prefix) => _cache.removeWhere((k, _) => k.startsWith(prefix));

  /// a picture from the gallery, ≤ 1 MB: (mime, base64)
  static Future<(String, String)?> pick(BuildContext context) async {
    XFile? f;
    try {
      f = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 80, maxWidth: 1600, maxHeight: 1600);
    } catch (_) {
      f = null;
    }
    if (f == null) return null;
    final bytes = await f.readAsBytes();
    if (bytes.length > 1000000) {
      if (context.mounted) JphUi.toast(context, {'success': false, 'message': 'الصورة كبيرة — اختار صورة أصغر من 1 ميجا'});
      return null;
    }
    final n = f.name.toLowerCase();
    return (n.endsWith('.png') ? 'image/png' : n.endsWith('.webp') ? 'image/webp' : 'image/jpeg', base64Encode(bytes));
  }

  static Future<bool> upload(BuildContext context, String path, (String, String) img, {String ok = 'اتحفظت الصورة ✅'}) async {
    final r = await ApiService.post({'action': 'cash_post', 'path': path, 'method': 'put', 'body': {'mime': img.$1, 'image': img.$2}, 'ok': ok});
    _cache.clear();
    if (context.mounted) JphUi.toast(context, r);
    return r['success'] == true;
  }
}
