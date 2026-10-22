import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'capture.dart';
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

  /// Sends a report from your own UI: a note, and optionally a screenshot and a
  /// recording (see [ScreenRecorder]). Returns the issue's id; throws
  /// [LoggerAIReportException] with a message for the user when it can't be sent.
  /// [onProgress] gets the bytes sent and the total, to show the upload.
  static Future<int> report(String note,
      {Uint8List? screenshot, Uint8List? recording, String? contact, void Function(int sent, int total)? onProgress}) {
    final c = _client;
    if (c == null) return Future.error(LoggerAIReportException("LoggerAI isn't started."));
    return c.report(note, screenshot: screenshot, recording: recording, contact: contact, onProgress: onProgress);
  }

  /// A screenshot of the app as PNG, with text fields and [LoggerAIMask] areas painted over.
  static Future<Uint8List?> screenshot() => screenshotPng(maskTextFields: _client?.options.maskTextFields ?? true);

  /// "Report a problem": the user describes it, can keep a screenshot of the screen
  /// they were on and record the screen while they show what goes wrong. The team
  /// gets an issue with all of it and the session's steps, and a Slack message.
  ///
  /// Call it from a button, a menu or a shake handler.
  static Future<void> showReportSheet(
    BuildContext context, {
    String title = 'Report a problem',
    String hint = 'What went wrong?',
    bool askContact = false,
    bool allowRecording = true,
    bool includeScreenshot = true,
    Duration maxRecording = const Duration(seconds: 60),
  }) async {
    final nav = Navigator.of(context, rootNavigator: true);
    final mask = _client?.options.maskTextFields ?? true;
    // The picture is of the screen they were on, before the sheet covers it.
    final draft = ReportDraft(screenshot: includeScreenshot ? await screenshotPng(maskTextFields: mask) : null);
    while (nav.mounted) {
      final next = await showModalBottomSheet<String>(
        context: nav.overlay?.context ?? nav.context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ReportSheet(title: title, hint: hint, draft: draft, askContact: askContact, allowRecording: allowRecording),
      );
      if (next != 'record' || !nav.mounted) return;
      final recorder = ScreenRecorder(maxDuration: maxRecording, maskTextFields: mask);
      final pill = OverlayEntry(builder: (_) => _RecordingPill(recorder: recorder));
      nav.overlay?.insert(pill);
      recorder.start();
      try {
        draft.recording = await recorder.done;
        draft.recordingLength = recorder.elapsed;
      } finally {
        pill.remove();
      }
    }
  }
}

/// What the user has put in a report so far (kept while they record).
class ReportDraft {
  ReportDraft({this.screenshot});

  Uint8List? screenshot;
  bool keepScreenshot = true;
  Uint8List? recording;
  Duration? recordingLength;
  final note = TextEditingController();
  final contact = TextEditingController();
}

String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Shown over the app while it records: how long so far, and Stop.
class _RecordingPill extends StatefulWidget {
  const _RecordingPill({required this.recorder});

  final ScreenRecorder recorder;

  @override
  State<_RecordingPill> createState() => _RecordingPillState();
}

class _RecordingPillState extends State<_RecordingPill> {
  late final Timer _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
    if (mounted) setState(() {});
  });

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final left = widget.recorder.maxDuration - widget.recorder.elapsed;
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Material(
            color: const Color(0xEE1F2328),
            shape: const StadiumBorder(),
            elevation: 6,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 4, 4, 4),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.fiber_manual_record, color: Color(0xFFEF4444), size: 14),
                const SizedBox(width: 8),
                Text('Recording ${_clock(widget.recorder.elapsed)}${left.inSeconds <= 10 ? ' · ${left.inSeconds}s left' : ''}',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()])),
                const SizedBox(width: 4),
                TextButton(
                  key: const Key('loggerai-record-stop'),
                  onPressed: widget.recorder.stop,
                  style: TextButton.styleFrom(foregroundColor: Colors.white),
                  child: const Text('Stop'),
                ),
              ]),
            ),
          ),
        ),
      ),
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
  const ReportSheet({
    super.key,
    this.title = 'Report a problem',
    this.hint = 'What went wrong?',
    ReportDraft? draft,
    this.askContact = false,
    this.allowRecording = true,
  }) : _draft = draft;

  final String title;
  final String hint;
  final ReportDraft? _draft;
  final bool askContact;
  final bool allowRecording;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  late final ReportDraft _draft = widget._draft ?? ReportDraft();
  bool _sending = false;
  bool _sent = false;
  String? _error;
  // Upload progress, 0..1; null while getting ready (before any bytes go out).
  double? _progress;

  Future<void> _send() async {
    final note = _draft.note.text.trim();
    if (note.isEmpty) {
      setState(() => _error = 'Tell us what went wrong.');
      return;
    }
    setState(() {
      _sending = true;
      _progress = null;
      _error = null;
    });
    try {
      await LoggerAI.report(note,
          screenshot: _draft.keepScreenshot ? _draft.screenshot : null,
          recording: _draft.recording,
          contact: widget.askContact ? _draft.contact.text : null, onProgress: (sent, total) {
        if (mounted && total > 0) setState(() => _progress = sent / total);
      });
      if (mounted) setState(() => _sent = true);
    } on LoggerAIReportException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _sendingLabel() {
    final p = _progress;
    if (p == null) return 'Getting ready…';
    if (p >= 1) return 'Almost done…';
    final what = _draft.recording != null ? 'recording' : 'report';
    return 'Uploading $what… ${(p * 100).floor()}%';
  }

  Widget _chip({required Widget leading, required String label, required VoidCallback onRemove, required Key removeKey}) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 6, 2, 6),
      decoration: BoxDecoration(border: Border.all(color: theme.dividerColor), borderRadius: BorderRadius.circular(12)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        leading,
        const SizedBox(width: 8),
        Text(label, style: theme.textTheme.bodyMedium),
        IconButton(key: removeKey, onPressed: onRemove, icon: const Icon(Icons.close, size: 18), tooltip: 'Remove', visualDensity: VisualDensity.compact),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _draft;
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
          : SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Text(widget.title, style: theme.textTheme.titleLarge),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('loggerai-report-text'),
                  controller: d.note,
                  autofocus: d.recording == null,
                  minLines: 3,
                  maxLines: 6,
                  maxLength: 2000,
                  decoration: InputDecoration(hintText: widget.hint, border: const OutlineInputBorder()),
                ),
                if (widget.askContact) ...[
                  const SizedBox(height: 4),
                  TextField(
                    key: const Key('loggerai-report-contact'),
                    controller: d.contact,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Your email, if we may reply (optional)', border: OutlineInputBorder()),
                  ),
                  const SizedBox(height: 12),
                ],
                Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  if (d.screenshot != null && d.keepScreenshot)
                    _chip(
                      leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.memory(d.screenshot!, height: 40)),
                      label: 'Screenshot',
                      removeKey: const Key('loggerai-report-remove-screenshot'),
                      onRemove: () => setState(() => d.keepScreenshot = false),
                    ),
                  if (d.recording != null)
                    _chip(
                      leading: const Icon(Icons.videocam_outlined),
                      label: 'Recording ${_clock(d.recordingLength ?? Duration.zero)}',
                      removeKey: const Key('loggerai-report-remove-recording'),
                      onRemove: () => setState(() => d.recording = null),
                    )
                  else if (widget.allowRecording)
                    OutlinedButton.icon(
                      key: const Key('loggerai-report-record'),
                      onPressed: _sending ? null : () => Navigator.of(context).pop('record'),
                      icon: const Icon(Icons.fiber_manual_record, color: Color(0xFFEF4444), size: 16),
                      label: const Text('Record the problem'),
                    ),
                ]),
                if (widget.allowRecording && d.recording == null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text('Show us what happens, then tap Stop. Text you type is hidden in the recording.', style: theme.textTheme.bodySmall),
                  ),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
                  ),
                const SizedBox(height: 16),
                if (_sending) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(key: const Key('loggerai-report-progress'), value: _progress, minHeight: 6),
                  ),
                  const SizedBox(height: 8),
                  Text(_sendingLabel(), key: const Key('loggerai-report-progress-label'), style: theme.textTheme.bodyMedium, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                ],
                FilledButton(
                  key: const Key('loggerai-report-send'),
                  onPressed: _sending ? null : _send,
                  child: Text(_sending ? 'Sending…' : 'Send'),
                ),
              ]),
            ),
    );
  }
}
