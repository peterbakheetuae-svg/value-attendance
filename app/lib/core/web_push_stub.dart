// Not the web: nothing to do (Android uses Firebase push).
bool supported() => false;
bool ios() => false;
bool standalone() => false;
String permission() => 'unsupported';
Future<String> current(String key) async => '';
Future<String> prompt(String key) async => '';
Future<bool> installHint() async => false;
