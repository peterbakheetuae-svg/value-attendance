import '../../core/api.dart';
import '../../core/session.dart';

/// Connects the original JPH screens to the Value Attendance session and API client.
/// Set once in main() before runApp.
class JphBridge {
  JphBridge._();
  static late Session session;
  static ApiClient get api => session.api;

  /// Original screens identify people by "uid" = the employee code. The API uses UUIDs.
  static final Map<String, String> codeToId = {};
  static final Map<String, String> idToCode = {};

  static void remember(String code, String id) {
    if (code.isEmpty || id.isEmpty) return;
    codeToId[code.toUpperCase()] = id;
    idToCode[id] = code;
  }

  static String get myId => session.id;
  static String get myCode => session.me?['code']?.toString() ?? '';

  /// Absolute URL for a signed media path returned by /media/links.
  static String mediaUrl(String path) => '${api.baseUrl}$path';
}
