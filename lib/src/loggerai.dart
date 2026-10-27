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
  ///
  /// [hash] is the signature of [id] from your server (see "My reports" in the README):
  /// with it the user sees their reports on any device; without it, the ones sent from this device.
  static void setUser(String? id, {String? hash}) {
    final c = _client;
    if (c == null) return;
    c.user = id;
    c.userHash = id == null ? null : hash;
  }

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

  /// Sends a report from your own UI: a note, and optionally screenshots and a recording
  /// (see [ScreenRecorder]). Returns the issue's id; throws [LoggerAIReportException]
  /// with a message for the user when it can't be sent. [onProgress] gets the bytes
  /// sent and the total, to show the upload.
  static Future<int> report(String note,
      {Uint8List? screenshot,
      List<Uint8List> screenshots = const [],
      Uint8List? recording,
      String? contact,
      void Function(int sent, int total)? onProgress}) {
    final c = _client;
    if (c == null) return Future.error(LoggerAIReportException("LoggerAI isn't started."));
    return c.report(note, screenshot: screenshot, screenshots: screenshots, recording: recording, contact: contact, onProgress: onProgress);
  }

  /// The reports this user sent, newest first (see [setUser] for signed-in users).
  static Future<List<MyReport>> myReports() {
    final c = _client;
    if (c == null) return Future.error(LoggerAIReportException("LoggerAI isn't started."));
    return c.myReports();
  }

  /// A screenshot of the app as PNG, with text fields and [LoggerAIMask] areas painted over.
  static Future<Uint8List?> screenshot() => screenshotPng(maskTextFields: _client?.options.maskTextFields ?? true);

  /// "Report a problem": the user describes it, can take screenshots of the app and record
  /// the screen while they show what goes wrong. The team gets an issue with all of it and
  /// the session's steps, and a Slack message.
  ///
  /// Call it from a button, a menu or a shake handler.
  static Future<void> showReportSheet(
    BuildContext context, {
    String title = 'Report a problem',
    String hint = 'What went wrong?',
    bool askContact = false,
    bool allowRecording = true,
    bool allowScreenshots = true,
    bool showMyReports = true,
    Duration maxRecording = const Duration(seconds: 60),
    @Deprecated('Screenshots are taken with the camera button now') bool includeScreenshot = true,
  }) async {
    final nav = Navigator.of(context, rootNavigator: true);
    final mask = _client?.options.maskTextFields ?? true;
    final draft = ReportDraft();
    while (nav.mounted) {
      final next = await showModalBottomSheet<String>(
        context: nav.overlay?.context ?? nav.context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => ReportSheet(
            title: title, hint: hint, draft: draft, askContact: askContact, allowRecording: allowRecording, allowScreenshots: allowScreenshots, showMyReports: showMyReports),
      );
      if (!nav.mounted) return;
      if (next == 'screenshot') {
        // The sheet has closed: wait for the screen under it to be drawn, then take it.
        await WidgetsBinding.instance.endOfFrame;
        await Future<void>.delayed(const Duration(milliseconds: 120));
        final shot = await screenshotPng(maskTextFields: mask);
        if (shot != null) draft.screenshots.add(shot);
        continue;
      }
      if (next == 'my-reports') {
        if (nav.mounted) await showMyReportsSheet(nav.overlay?.context ?? nav.context);
        return;
      }
      if (next != 'record') return;
      final recorder = ScreenRecorder(maxDuration: maxRecording, maskTextFields: mask);
      final pill = OverlayEntry(
          builder: (_) => _RecordingPill(recorder: recorder, allowScreenshots: allowScreenshots, draft: draft, maskTextFields: mask));
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

  /// "My reports": what this user sent, open and resolved.
  static Future<void> showMyReportsSheet(BuildContext context, {String title = 'My reports'}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => MyReportsSheet(title: title),
    );
  }
}

/// What the user has put in a report so far (kept while they record or take screenshots).
class ReportDraft {
  ReportDraft();

  static const maxScreenshots = 5;

  final screenshots = <Uint8List>[];
  Uint8List? recording;
  Duration? recordingLength;
  final note = TextEditingController();
  final contact = TextEditingController();

  bool get screenshotsFull => screenshots.length >= maxScreenshots;
}

String _clock(Duration d) => '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

/// Shown over the app while it records: the time so far, a camera for a screenshot, and Stop.
class _RecordingPill extends StatefulWidget {
  const _RecordingPill({required this.recorder, required this.draft, required this.allowScreenshots, required this.maskTextFields});

  final ScreenRecorder recorder;
  final ReportDraft draft;
  final bool allowScreenshots;
  final bool maskTextFields;

  @override
  State<_RecordingPill> createState() => _RecordingPillState();
}

class _RecordingPillState extends State<_RecordingPill> {
  Timer? _tick;
  bool _hidden = false; // while a screenshot is taken, so the pill isn't in it
  bool _flash = false;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _screenshot() async {
    if (widget.draft.screenshotsFull) return;
    setState(() => _hidden = true);
    await WidgetsBinding.instance.endOfFrame;
    final shot = await screenshotPng(maskTextFields: widget.maskTextFields);
    if (shot != null) widget.draft.screenshots.add(shot);
    if (!mounted) return;
    setState(() {
      _hidden = false;
      _flash = shot != null;
    });
    await Future<void>.delayed(const Duration(milliseconds: 900));
    if (mounted) setState(() => _flash = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_hidden) return const SizedBox.shrink();
    final left = widget.recorder.maxDuration - widget.recorder.elapsed;
    final shots = widget.draft.screenshots.length;
    const white = TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontFeatures: [FontFeature.tabularFigures()]);
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
                Text(
                  _flash ? 'Screenshot saved' : 'Recording ${_clock(widget.recorder.elapsed)}${left.inSeconds <= 10 ? ' · ${left.inSeconds}s left' : ''}',
                  key: const Key('loggerai-record-clock'),
                  style: white,
                ),
                if (widget.allowScreenshots) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    key: const Key('loggerai-record-screenshot'),
                    onPressed: widget.draft.screenshotsFull ? null : _screenshot,
                    tooltip: widget.draft.screenshotsFull ? 'Up to ${ReportDraft.maxScreenshots} screenshots' : 'Take a screenshot',
                    icon: Badge(
                      isLabelVisible: shots > 0,
                      label: Text('$shots'),
                      child: const Icon(Icons.photo_camera_outlined, color: Colors.white, size: 20),
                    ),
                  ),
                ],
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
    this.allowScreenshots = true,
    this.showMyReports = true,
  }) : _draft = draft;

  final String title;
  final String hint;
  final ReportDraft? _draft;
  final bool askContact;
  final bool allowRecording;
  final bool allowScreenshots;
  final bool showMyReports;

  @override
  State<ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<ReportSheet> {
  late final ReportDraft _draft = widget._draft ?? ReportDraft();
  bool _sending = false;
  int? _sentId;
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
      final id = await LoggerAI.report(note,
          screenshots: _draft.screenshots,
          recording: _draft.recording,
          contact: widget.askContact ? _draft.contact.text : null, onProgress: (sent, total) {
        if (mounted && total > 0) setState(() => _progress = sent / total);
      });
      if (mounted) setState(() => _sentId = id);
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

  Widget _sent(ThemeData theme) {
    final scheme = theme.colorScheme;
    final contact = widget.askContact ? _draft.contact.text.trim() : '';
    final parts = [
      'your note',
      if (_draft.screenshots.isNotEmpty) _draft.screenshots.length == 1 ? 'the screenshot' : '${_draft.screenshots.length} screenshots',
      if (_draft.recording != null) 'the recording',
    ];
    final what = parts.length == 1 ? parts.first : '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
    return Column(key: const Key('loggerai-report-sent'), mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      const SizedBox(height: 4),
      Center(
        child: Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(color: scheme.primaryContainer, shape: BoxShape.circle),
          child: Icon(Icons.mark_email_read_outlined, size: 32, color: scheme.onPrimaryContainer),
        ),
      ),
      const SizedBox(height: 16),
      Text('The team has your report', style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
      const SizedBox(height: 8),
      Text(
        'They have $what, and what happened in the app before it. They\'ll look into it and get back to you'
        '${contact.isNotEmpty ? ' at $contact' : ''}.',
        style: theme.textTheme.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
        textAlign: TextAlign.center,
      ),
      if ((_sentId ?? 0) > 0) ...[
        const SizedBox(height: 12),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(999)),
            child: Text('Report #$_sentId', style: theme.textTheme.labelLarge),
          ),
        ),
      ],
      const SizedBox(height: 20),
      FilledButton(key: const Key('loggerai-report-done'), onPressed: () => Navigator.of(context).pop(), child: const Text('Done')),
      if (widget.showMyReports) ...[
        const SizedBox(height: 4),
        TextButton(
          key: const Key('loggerai-report-see-mine'),
          onPressed: () => Navigator.of(context).pop('my-reports'),
          child: const Text('See my reports'),
        ),
      ],
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = _draft;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: _sentId != null
          ? _sent(theme)
          : SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Row(children: [
                  Expanded(child: Text(widget.title, style: theme.textTheme.titleLarge)),
                  if (widget.showMyReports)
                    TextButton(
                      key: const Key('loggerai-report-my-reports'),
                      onPressed: _sending ? null : () => Navigator.of(context).pop('my-reports'),
                      child: const Text('My reports'),
                    ),
                ]),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('loggerai-report-text'),
                  controller: d.note,
                  autofocus: d.recording == null && d.screenshots.isEmpty,
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
                  for (final (i, shot) in d.screenshots.indexed)
                    _chip(
                      leading: ClipRRect(borderRadius: BorderRadius.circular(4), child: Image.memory(shot, height: 40)),
                      label: d.screenshots.length == 1 ? 'Screenshot' : 'Screenshot ${i + 1}',
                      removeKey: Key('loggerai-report-remove-screenshot-$i'),
                      onRemove: () => setState(() => d.screenshots.removeAt(i)),
                    ),
                  if (d.recording != null)
                    _chip(
                      leading: const Icon(Icons.videocam_outlined),
                      label: 'Recording ${_clock(d.recordingLength ?? Duration.zero)}',
                      removeKey: const Key('loggerai-report-remove-recording'),
                      onRemove: () => setState(() => d.recording = null),
                    ),
                ]),
                if (d.screenshots.isNotEmpty || d.recording != null) const SizedBox(height: 8),
                Wrap(spacing: 8, runSpacing: 8, children: [
                  if (widget.allowScreenshots && !d.screenshotsFull)
                    OutlinedButton.icon(
                      key: const Key('loggerai-report-screenshot'),
                      onPressed: _sending ? null : () => Navigator.of(context).pop('screenshot'),
                      icon: const Icon(Icons.photo_camera_outlined, size: 18),
                      label: const Text('Take a screenshot'),
                    ),
                  if (widget.allowRecording && d.recording == null)
                    OutlinedButton.icon(
                      key: const Key('loggerai-report-record'),
                      onPressed: _sending ? null : () => Navigator.of(context).pop('record'),
                      icon: const Icon(Icons.fiber_manual_record, color: Color(0xFFEF4444), size: 16),
                      label: const Text('Record the problem'),
                    ),
                ]),
                if ((widget.allowRecording && d.recording == null) || widget.allowScreenshots)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      widget.allowRecording && d.recording == null
                          ? 'Show us what happens, then tap Stop; the camera on the recording bar takes screenshots too. Text you type is hidden.'
                          : 'The sheet closes for a moment to take the screenshot. Text you type is hidden.',
                      style: theme.textTheme.bodySmall,
                    ),
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

/// "My reports": the reports this user sent, open ones first, with where each one is.
class MyReportsSheet extends StatefulWidget {
  const MyReportsSheet({super.key, this.title = 'My reports'});

  final String title;

  @override
  State<MyReportsSheet> createState() => _MyReportsSheetState();
}

class _MyReportsSheetState extends State<MyReportsSheet> {
  late Future<List<MyReport>> _load = LoggerAI.myReports();
  bool _resolved = false;

  static const _label = {'open': 'Received', 'investigating': 'Being looked at', 'resolved': 'Resolved'};

  String _when(DateTime t) {
    final d = DateTime.now().difference(t.toLocal());
    if (d.inMinutes < 1) return 'just now';
    if (d.inHours < 1) return '${d.inMinutes} min ago';
    if (d.inDays < 1) return '${d.inHours} h ago';
    if (d.inDays < 30) return '${d.inDays} d ago';
    final l = t.toLocal();
    return '${l.day}/${l.month}/${l.year}';
  }

  // The app's own colours: its primary (brand) colour for resolved and being
  // looked at, neutral for received. Not secondary/tertiary, which many apps
  // leave at Flutter's defaults (a light blue or teal).
  Widget _status(ThemeData theme, String status) {
    final scheme = theme.colorScheme;
    final (Color bg, Color fg, Color? border) = switch (status) {
      'resolved' => (scheme.primary, scheme.onPrimary, null),
      'investigating' => (Colors.transparent, scheme.primary, scheme.primary),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant, null),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(999), border: border == null ? null : Border.all(color: border)),
      child: Text(_label[status] ?? status, style: theme.textTheme.labelMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
    );
  }

  ButtonStyle _tabsStyle(ColorScheme scheme) => ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.primary : null),
        foregroundColor:
            WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurface),
        iconColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? scheme.onPrimary : scheme.onSurface),
        side: WidgetStatePropertyAll(BorderSide(color: scheme.outlineVariant)),
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.7,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(widget.title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          FutureBuilder<List<MyReport>>(
            future: _load,
            builder: (context, snap) {
              final all = snap.data ?? const <MyReport>[];
              final resolved = all.where((r) => r.resolved).length;
              String label(String name, int n) => snap.hasData ? '$name ($n)' : name;
              return SegmentedButton<bool>(
                key: const Key('loggerai-my-reports-tabs'),
                style: _tabsStyle(theme.colorScheme),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(value: false, label: Text(label('Open', all.length - resolved)), icon: const Icon(Icons.inbox_outlined)),
                  ButtonSegment(value: true, label: Text(label('Resolved', resolved)), icon: const Icon(Icons.task_alt)),
                ],
                selected: {_resolved},
                onSelectionChanged: (s) => setState(() => _resolved = s.first),
              );
            },
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<MyReport>>(
              future: _load,
              builder: (context, snap) {
                if (snap.connectionState != ConnectionState.done) {
                  return Center(child: CircularProgressIndicator(color: theme.colorScheme.primary));
                }
                if (snap.hasError) {
                  return Center(
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Text('${snap.error}', textAlign: TextAlign.center),
                      const SizedBox(height: 8),
                      TextButton(onPressed: () => setState(() => _load = LoggerAI.myReports()), child: const Text('Try again')),
                    ]),
                  );
                }
                final items = (snap.data ?? const <MyReport>[]).where((r) => r.resolved == _resolved).toList();
                if (items.isEmpty) {
                  return Center(
                    child: Text(
                        _resolved
                            ? 'Nothing resolved yet. Reports sent from this phone show here once the team resolves them.'
                            : 'No open reports. If something goes wrong, tell us from Report a problem.',
                        textAlign: TextAlign.center, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    final next = LoggerAI.myReports();
                    setState(() => _load = next);
                    await next.catchError((_) => <MyReport>[]);
                  },
                  child: ListView.separated(
                    key: const Key('loggerai-my-reports-list'),
                    itemCount: items.length,
                    separatorBuilder: (_, __) => const Divider(height: 1),
                    itemBuilder: (_, i) {
                      final r = items[i];
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(r.title, maxLines: 2, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                            'Report #${r.id} · sent ${_when(r.createdAt)}${r.resolvedAt != null ? ' · resolved ${_when(r.resolvedAt!)}' : ''}'),
                        trailing: _status(theme, r.status),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ]),
      ),
    );
  }
}
