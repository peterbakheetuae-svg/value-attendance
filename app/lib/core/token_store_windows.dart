// Windows DPAPI (CryptProtectData / CryptUnprotectData) through dart:ffi — no extra package.
// Only called on Windows (see TokenStore); on Android these functions are never reached.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

final class _Blob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptNative = Int32 Function(Pointer<_Blob> dataIn, Pointer<Uint16> description, Pointer<_Blob> entropy,
    Pointer<Void> reserved, Pointer<Void> prompt, Uint32 flags, Pointer<_Blob> dataOut);
typedef _CryptDart = int Function(Pointer<_Blob> dataIn, Pointer<Uint16> description, Pointer<_Blob> entropy,
    Pointer<Void> reserved, Pointer<Void> prompt, int flags, Pointer<_Blob> dataOut);
typedef _UnprotectNative = Int32 Function(Pointer<_Blob> dataIn, Pointer<Pointer<Uint16>> description,
    Pointer<_Blob> entropy, Pointer<Void> reserved, Pointer<Void> prompt, Uint32 flags, Pointer<_Blob> dataOut);
typedef _UnprotectDart = int Function(Pointer<_Blob> dataIn, Pointer<Pointer<Uint16>> description,
    Pointer<_Blob> entropy, Pointer<Void> reserved, Pointer<Void> prompt, int flags, Pointer<_Blob> dataOut);
typedef _LocalAllocNative = Pointer<Void> Function(Uint32 flags, IntPtr bytes);
typedef _LocalAllocDart = Pointer<Void> Function(int flags, int bytes);
typedef _LocalFreeNative = Pointer<Void> Function(Pointer<Void> mem);

const _cryptprotectUiForbidden = 0x1;
const _lptr = 0x0040; // LMEM_FIXED | LMEM_ZEROINIT
// app-specific DPAPI entropy (not a secret — it ships in the app): a casual unprotect call by another program
// without it fails; the real protection is DPAPI's binding to this Windows user account
final _entropy = utf8.encode('VALUNIVO.desktop.session.v1');

final _crypt32 = DynamicLibrary.open('crypt32.dll');
final _kernel32 = DynamicLibrary.open('kernel32.dll');
final _protect = _crypt32.lookupFunction<_CryptNative, _CryptDart>('CryptProtectData');
final _unprotect = _crypt32.lookupFunction<_UnprotectNative, _UnprotectDart>('CryptUnprotectData');
final _localAlloc = _kernel32.lookupFunction<_LocalAllocNative, _LocalAllocDart>('LocalAlloc');
final _localFree = _kernel32.lookupFunction<_LocalFreeNative, _LocalFreeNative>('LocalFree');

Pointer<_Blob> _blob(List<int> bytes) {
  final b = _localAlloc(_lptr, sizeOf<_Blob>()).cast<_Blob>();
  final data = _localAlloc(_lptr, bytes.isEmpty ? 1 : bytes.length).cast<Uint8>();
  data.asTypedList(bytes.length).setAll(0, bytes);
  b.ref
    ..cbData = bytes.length
    ..pbData = data;
  return b;
}

void _freeBlob(Pointer<_Blob> b, {bool wipe = false}) {
  if (wipe) b.ref.pbData.asTypedList(b.ref.cbData).fillRange(0, b.ref.cbData, 0);
  _localFree(b.ref.pbData.cast());
  _localFree(b.cast());
}

String? _run(List<int> input, bool seal) {
  final inBlob = _blob(input);
  final entropy = _blob(_entropy);
  final out = _localAlloc(_lptr, sizeOf<_Blob>()).cast<_Blob>();
  try {
    final ok = seal
        ? _protect(inBlob, nullptr, entropy, nullptr, nullptr, _cryptprotectUiForbidden, out)
        : _unprotect(inBlob, nullptr, entropy, nullptr, nullptr, _cryptprotectUiForbidden, out);
    if (ok == 0 || out.ref.pbData == nullptr) return null;
    final bytes = Uint8List.fromList(out.ref.pbData.asTypedList(out.ref.cbData));
    // DPAPI allocated the output with LocalAlloc: wipe + free it
    out.ref.pbData.asTypedList(out.ref.cbData).fillRange(0, out.ref.cbData, 0);
    _localFree(out.ref.pbData.cast());
    return seal ? base64Encode(bytes) : utf8.decode(bytes);
  } catch (_) {
    return null;
  } finally {
    _freeBlob(inBlob, wipe: seal);
    _freeBlob(entropy);
    _localFree(out.cast());
  }
}

String? protect(String plain) => _run(utf8.encode(plain), true);

String? unprotect(String sealed) {
  try {
    return _run(base64Decode(sealed), false);
  } catch (_) {
    return null;
  }
}
