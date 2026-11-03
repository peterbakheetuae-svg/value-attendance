import 'package:flutter/material.dart';
import '../design/glass.dart';
import 'api.dart';
import 'i18n.dart';

/// Human message for any API failure (never a raw stack).
String errorText(Object e) {
  if (e is ApiException) {
    if (e.isNetwork) return t('network_error');
    if (e.status == 401) return t('session_expired');
    if (e.status == 403) return t('forbidden');
    if (e.status == 404) return t('not_found');
    return e.message;
  }
  return t('unexpected_error');
}

/// Loads data once (and on [reload]) with the design-system loading / error states.
class AsyncView<T> extends StatefulWidget {
  final Future<T> Function() load;
  final Widget Function(BuildContext, T, Future<void> Function() reload) builder;
  const AsyncView({super.key, required this.load, required this.builder});
  @override
  State<AsyncView<T>> createState() => _AsyncViewState<T>();
}

class _AsyncViewState<T> extends State<AsyncView<T>> {
  late Future<T> _f;
  @override
  void initState() { super.initState(); _f = widget.load(); }

  Future<void> _reload() async {
    final f = widget.load();
    setState(() => _f = f);
    try { await f; } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<T>(
        future: _f,
        builder: (ctx, s) {
          if (s.connectionState != ConnectionState.done) return const LoadingState();
          if (s.hasError) return ErrorState(errorText(s.error!), onRetry: _reload, retryLabel: t('retry'));
          return widget.builder(ctx, s.data as T, _reload);
        },
      );
}

/// Map helpers for dynamic JSON.
extension JsonX on Map<String, dynamic> {
  List<Map<String, dynamic>> list(String k) => ((this[k] as List?) ?? const []).cast<Map<String, dynamic>>();
  Map<String, dynamic>? obj(String k) => this[k] as Map<String, dynamic>?;
  String s(String k) => this[k]?.toString() ?? '';
}
