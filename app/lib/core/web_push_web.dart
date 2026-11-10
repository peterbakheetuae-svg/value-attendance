import 'dart:js_interop';

/// window.vaPush — app/web_push/va-push.js (added to index.html at build time).
@JS('vaPush')
external _VaPush? get _va;

extension type _VaPush._(JSObject _) implements JSObject {
  external bool supported();
  external bool ios();
  external bool standalone();
  external String permission();
  external JSPromise<JSString> current(String key);
  external JSPromise<JSString> prompt(String key);
  external JSPromise<JSBoolean> installHint();
}

bool supported() => _va?.supported() ?? false;
bool ios() => _va?.ios() ?? false;
bool standalone() => _va?.standalone() ?? false;
String permission() => _va?.permission() ?? 'unsupported';
Future<String> current(String key) async => _va == null ? '' : (await _va!.current(key).toDart).toDart;
Future<String> prompt(String key) async => _va == null ? '' : (await _va!.prompt(key).toDart).toDart;
Future<bool> installHint() async => _va == null ? false : (await _va!.installHint().toDart).toDart;
