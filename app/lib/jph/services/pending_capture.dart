import 'camera_service.dart';

/// One approved capture, retained so it can be retried.
class PendingCapture {
  const PendingCapture({required this.capture, required this.capturedAt});

  final CaptureResult capture;
  final DateTime capturedAt;
}

/// Holds the approved capture for the check-in currently in flight.
///
/// Why this exists: a failed upload or check-in used to force the user to take
/// a brand-new photo, which produced a second stored object and orphaned the
/// first. Keeping the capture lets the retry resend the *same* bytes with the
/// *same* `uploadId`, so the server can recognise it as a retry.
///
/// The store lives in the widget's State, so ordinary `setState` rebuilds keep
/// it. It does not survive an app restart — out of scope by design.
class PendingCaptureStore {
  PendingCaptureStore({this.ttl = const Duration(minutes: 15)});

  /// A capture older than this is discarded rather than reused: attaching a
  /// minutes-old photo to a new check-in would be wrong even though the server
  /// would still accept it inside its 24-hour window.
  final Duration ttl;

  PendingCapture? _pending;

  bool get hasPending => _pending != null;

  /// Returns the reusable capture, or null when there is none or it is stale.
  /// A stale entry is dropped so a later call cannot resurrect it.
  CaptureResult? take(DateTime now) {
    final pending = _pending;
    if (pending == null) return null;
    if (now.difference(pending.capturedAt) >= ttl) {
      _pending = null;
      return null;
    }
    return pending.capture;
  }

  /// Retains a capture that the user has approved.
  void put(CaptureResult capture, DateTime now) {
    _pending = PendingCapture(capture: capture, capturedAt: now);
  }

  /// Drops the capture: after confirmed success, or on explicit cancellation.
  void clear() {
    _pending = null;
  }
}
