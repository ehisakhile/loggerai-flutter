import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'client.dart';

/// LoggerAI for Flutter.
///
/// ```dart
/// void main() => LoggerAI.run(
///       const LoggerAIOptions(publicKey: 'pk_live_...', release: '1.4.2', traceHosts: ['api.shop.com']),
///       () => runApp(const ShopApp()),
///     );
///
/// MaterialApp(navigatorObservers: [LoggerAI.navigatorObserver], ...)
/// ```
class LoggerAI {
  LoggerAI._();

  static Client? _client;

  /// The client, once [init] or [run] has been called.
  static Client? get client => _client;

  /// Starts LoggerAI and runs the app, catching every error it doesn't: Flutter's
  /// own (build, layout, gestures), uncaught async errors and platform errors.
  static Future<void> run(LoggerAIOptions options, FutureOr<void> Function() appRunner) async {
    await runZonedGuarded(() async {
      WidgetsFlutterBinding.ensureInitialized();
      init(options);
      await appRunner();
    }, (error, stack) {
      _client?.error(error, stack, source: 'zone');
      if (kDebugMode) FlutterError.dumpErrorToConsole(FlutterErrorDetails(exception: error, stack: stack));
    });
  }

  /// Starts LoggerAI without wrapping the app (when you set up error handling yourself).
  /// Call it after `WidgetsFlutterBinding.ensureInitialized()`.
  static Client init(LoggerAIOptions options) {
    _client?.close();
    final c = Client(options);
    _client = c;
    if (!c.enabled) return c;
    c.start();
    final previousFlutter = FlutterError.onError;
    FlutterError.onError = (details) {
      if (!details.silent) _client?.error(details.exception, details.stack, source: details.library ?? 'flutter');
      (previousFlutter ?? FlutterError.presentError)(details);
    };
    final previousPlatform = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _client?.error(error, stack, source: 'platform');
      return previousPlatform?.call(error, stack) ?? false;
    };
    return c;
  }

  /// Report an error you caught but still want to see.
  static void captureException(Object error, [StackTrace? stack, Map<String, Object?>? context]) =>
      _client?.error(error, stack ?? StackTrace.current, handled: true, context: context);

  /// Something worth having in the session's timeline (`custom_event`).
  static void event(String name, [Map<String, Object?> data = const {}]) => _client?.event('custom_event', {'name': name, ...data});

  /// Count the session against a user: pass an opaque id, never an email or a name.
  static void setUser(String? id) => _client?.user = id;

  /// The screen the user is on, when you don't use [navigatorObserver] (or for tabs).
  static void setScreen(String name) {
    final c = _client;
    if (c == null || c.screen == name) return;
    final from = c.screen;
    c.screen = name;
    c.event('page_view', {'url': name, 'title': name, if (from != null) 'from': from});
  }

  /// Send everything now.
  static Future<void> flush() => _client?.flush() ?? Future.value();

  /// The current session's id, e.g. to show to support.
  static String? get sessionId => _client?.sessionId;

  /// Records each screen as the user moves through the app.
  static final NavigatorObserver navigatorObserver = LoggerAINavigatorObserver();

  /// A sheet where the user describes a problem. It lands in the session's timeline
  /// in LoggerAI, with everything that happened before it.
  static Future<void> showReportSheet(BuildContext context, {String title = 'Report a problem', String hint = 'What went wrong?'}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ReportSheet(title: title, hint: hint),
    );
  }
}

/// Records each screen as the user moves through the app. Add it to your
/// MaterialApp's `navigatorObservers` (or GoRouter's `observers`).
class LoggerAINavigatorObserver extends NavigatorObserver {
  void _screen(Route<dynamic>? route) {
    if (route is! PageRoute) return; // dialogs and sheets don't change the screen
    final name = route.settings.name;
    LoggerAI.setScreen(name == null || name.isEmpty ? route.runtimeType.toString() : name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => _screen(route);
  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) => _screen(newRoute);
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) => _screen(previousRoute);
}

class ReportSheet extends StatefulWidget {
  const ReportSheet({super.key, this.title = 'Report a problem', this.hint = 'What went wrong?'});

  final String title;
  final String hint;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  final _text = TextEditingController();
  bool _sent = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final note = _text.text.trim();
    if (note.isEmpty) return;
    LoggerAI.event('issue_reported', {'note': note, 'screen': LoggerAI.client?.screen});
    await LoggerAI.flush();
    if (mounted) setState(() => _sent = true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: _sent
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.check_circle_outline, size: 40),
              const SizedBox(height: 12),
              Text('Thanks: the team can see what happened.', style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Close')),
            ])
          : Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(widget.title, style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                key: const Key('loggerai-report-text'),
                controller: _text,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                maxLength: 2000,
                decoration: InputDecoration(hintText: widget.hint, border: const OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              FilledButton(key: const Key('loggerai-report-send'), onPressed: _send, child: const Text('Send')),
            ]),
    );
  }
}
