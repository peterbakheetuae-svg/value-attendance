import 'dart:typed_data';
import 'package:file_saver/file_saver.dart';

/// Saves bytes on web (browser download) and Android (Downloads / share target).
Future<void> saveBytes(String baseName, String ext, Uint8List bytes, {MimeType mime = MimeType.other}) async {
  await FileSaver.instance.saveFile(name: baseName, bytes: bytes, ext: ext, mimeType: mime);
}

Future<void> saveXlsx(String baseName, Uint8List bytes) =>
    saveBytes(baseName, 'xlsx', bytes, mime: MimeType.microsoftExcel);
