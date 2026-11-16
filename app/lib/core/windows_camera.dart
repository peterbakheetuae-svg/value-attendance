import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import '../jph/widgets/glass_dialog.dart';
import 'platform_info.dart';

/// Windows app: `ImagePicker().pickImage(source: ImageSource.camera)` has no camera of its own on Windows.
/// This gives it one (the PC's webcam, through the official camera_windows plugin), so every existing
/// «صوّر بالكاميرا» / check-in selfie keeps working unchanged. Android and web never use this.
class WindowsCamera implements ImagePickerCameraDelegate {
  WindowsCamera._(this._nav);
  final GlobalKey<NavigatorState> _nav;

  static void register(GlobalKey<NavigatorState> nav) {
    if (!PlatformInfo.isWindows) return;
    final p = ImagePickerPlatform.instance;
    if (p is CameraDelegatingImagePickerPlatform) p.cameraDelegate = WindowsCamera._(nav);
  }

  @override
  Future<XFile?> takePhoto({ImagePickerCameraDelegateOptions options = const ImagePickerCameraDelegateOptions()}) async {
    final ctx = _nav.currentContext;
    if (ctx == null) return null;
    final cams = await availableCameras();
    if (cams.isEmpty) throw StateError('لا توجد كاميرا متصلة بالكمبيوتر');
    final want = options.preferredCameraDevice == CameraDevice.front ? CameraLensDirection.front : CameraLensDirection.back;
    final cam = cams.firstWhere((c) => c.lensDirection == want, orElse: () => cams.first);
    if (!ctx.mounted) return null;
    return showDialog<XFile?>(context: ctx, barrierDismissible: false, builder: (_) => _CaptureDialog(camera: cam));
  }

  @override
  Future<XFile?> takeVideo({ImagePickerCameraDelegateOptions options = const ImagePickerCameraDelegateOptions()}) async =>
      null; // the app never records video
}

class _CaptureDialog extends StatefulWidget {
  final CameraDescription camera;
  const _CaptureDialog({required this.camera});
  @override
  State<_CaptureDialog> createState() => _CaptureDialogState();
}

class _CaptureDialogState extends State<_CaptureDialog> {
  late final CameraController _c =
      CameraController(widget.camera, ResolutionPreset.medium, enableAudio: false);
  late final Future<void> _ready = _c.initialize();
  bool _busy = false;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _shoot() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final x = await _c.takePicture();
      if (mounted) Navigator.pop(context, x);
    } catch (_) {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: GlassAlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        content: SizedBox(
          width: 560,
          child: AspectRatio(
            aspectRatio: 4 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: FutureBuilder<void>(
                future: _ready,
                builder: (_, s) {
                  if (s.hasError) {
                    return const Center(child: Text('مش قادر أفتح الكاميرا — اتأكد إنها متوصلة ومسموح للتطبيقات تستخدمها.',
                        textAlign: TextAlign.center));
                  }
                  if (s.connectionState != ConnectionState.done) return const Center(child: CircularProgressIndicator());
                  return CameraPreview(_c);
                },
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('إلغاء')),
          FilledButton.icon(
            onPressed: _busy ? null : _shoot,
            icon: const Icon(Icons.photo_camera_rounded),
            label: const Text('صوّر'),
          ),
        ],
      ),
    );
  }
}
