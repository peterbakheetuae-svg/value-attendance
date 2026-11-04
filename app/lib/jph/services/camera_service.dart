import 'dart:io';
import 'dart:convert';
import 'dart:typed_data'; // ⬅️ أضف هذا السطر
import 'package:camera/camera.dart';
import 'package:geolocator/geolocator.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';

import 'uuid_v4.dart';

class CaptureResult {
  final File file;
  final String base64;
  final String location;

  /// Stable identity of *this* capture, generated once when the photo is taken.
  ///
  /// It is sent with the upload so a retry of the same capture is recognised as
  /// a retry instead of creating a second stored object. A genuinely new
  /// capture always gets a new value.
  final String uploadId;

  CaptureResult({
    required this.file,
    required this.base64,
    required this.location,
    required this.uploadId,
  });
}

class CameraService {
  CameraController? _controller;
  bool _isInitialized = false;
  CameraDescription? _frontCamera;

  /// 🔥 تهيئة الكاميرا عند الحاجة فقط
  Future<void> initialize() async {
    if (_isInitialized) return;

    // طلب إذن الموقع مرة واحدة
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      permission = await Geolocator.requestPermission();
    }

    final cams = await availableCameras();
    _frontCamera = cams.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.front,
      orElse: () => cams.first,
    );

    _controller = CameraController(
      _frontCamera!,
      ResolutionPreset.low,
      enableAudio: false,
      imageFormatGroup: ImageFormatGroup.jpeg,
    );

    await _controller!.initialize();
    _isInitialized = true;
  }

  /// 📸 التقاط صورة مع الموقع
  Future<CaptureResult> captureWithLocation(BuildContext context) async {
    try {
      // تأكد من تهيئة الكاميرا
      await initialize();

      // التقاط الصورة
      final XFile photo = await _controller!.takePicture();
      final originalBytes = await photo.readAsBytes();

      // ⬅️ ضغط الصورة (تحويل List<int> إلى Uint8List)
      final compressedBytes = await _compressImage(Uint8List.fromList(originalBytes));

      // حفظ الملف المؤقت
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg');
      await file.writeAsBytes(compressedBytes);

      // الحصول على الموقع
      final position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.low,
      );

      return CaptureResult(
        file: file,
        base64: base64Encode(compressedBytes),
        location: "${position.latitude},${position.longitude}",
        // One id per capture — minted here, not at request time, so every
        // retry of this photo carries the same token.
        uploadId: uuidV4(),
      );
    } catch (e) {
      // في حالة حدوث خطأ، أغلاق الكاميرا
      await dispose();
      rethrow;
    }
  }

  /// 🔥 ضغط الصورة باستخدام flutter_image_compress
  Future<Uint8List> _compressImage(Uint8List originalBytes) async {
    try {
      // ضغط الصورة إلى جودة 70% وحجم 800x800 كحد أقصى
      final compressedBytes = await FlutterImageCompress.compressWithList(
        originalBytes,
        minHeight: 800,
        minWidth: 800,
        quality: 70,
        format: CompressFormat.jpeg,
      );

      print('📸 حجم الصورة: ${originalBytes.length ~/ 1024}KB -> ${compressedBytes.length ~/ 1024}KB');
      return compressedBytes;
    } catch (e) {
      print('⚠️ خطأ في ضغط الصورة: $e');
      // في حالة فشل الضغط، إرجاع الصورة الأصلية
      return originalBytes;
    }
  }

  /// 🔥 إغلاق الكاميرا وتحرير الذاكرة
  Future<void> dispose() async {
    await _controller?.dispose();
    _controller = null;
    _isInitialized = false;
    _frontCamera = null;
  }

  /// 🔥 التحقق مما إذا كانت الكاميرا مهيأة
  bool get isInitialized => _isInitialized;
}