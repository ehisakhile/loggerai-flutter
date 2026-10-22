import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import 'frames.dart';
import 'platform_stub.dart' if (dart.library.io) 'platform_io.dart' as platform;
import 'redact.dart';

const sdkVersion = '0.1.0';
const defaultEndpoint = 'https://loggerapp.ehigiator.com/api/v1/ingest/batch';
const _maxEvents = 1000;
const _maxErrors = 100;

/// Settings for [LoggerAI.run] and [LoggerAI.init].
class LoggerAIOptions {
  const LoggerAIOptions({
    required this.publicKey,
    this.endpoint = defaultEndpoint,
    this.service = 'app',
    this.environment = kReleaseMode ? 'production' : 'development',
    this.release,
    this.appPackages = const [],
    this.traceHosts = const [],
    this.captureNetwork = true,
    this.flushInterval = const Duration(seconds: 10),
    this.sessionTimeout = const Duration(minutes: 30),
    this.enabled = true,
    this.reportEndpoint,
    this.maskTextFields = true,
  });

  /// The project's public key (pk_live_...). Safe to ship in the app.
  final String publicKey;
  final String endpoint;

  /// Names the app in LoggerAI, e.g. "mobile".
  final String service;
  final String environment;

  /// Your app's version or build, so LoggerAI can say "since release X".
  final String? release;

  /// Your own packages (`['shop']`): stack frames in them are your code. By default
  /// everything but Flutter, Dart and well-known libraries counts.
  final List<String> appPackages;

  /// Hosts of your own API (`['api.shop.com']`). Calls to them carry `traceparent` and
  /// `x-loggerai-session`, so LoggerAI links each tap to the server request it caused.
  final List<String> traceHosts;

  /// Record calls made with package:http, Dio and HttpClient (not on the web).
  final bool captureNetwork;
  final Duration flushInterval;

  /// After this long in the background, coming back starts a new session.
  final Duration sessionTimeout;
  final bool enabled;

  /// Where reports go; by default the ingest endpoint with /report instead of /batch.
  final String? reportEndpoint;

  /// Paint over every text field in screenshots and recordings (as well as LoggerAIMask).
  final bool maskTextFields;
}

/// A report couldn't be sent: [message] says why, in words for the user.
class LoggerAIReportException implements Exception {
  LoggerAIReportException(this.message);

  final String message;

  @override
  String toString() => message;
}

final _random = Random.secure();

String hex(int bytes) => List.generate(bytes, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();

String uuid4() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

double _now() => DateTime.now().millisecondsSinceEpoch / 1000;

/// The buffer, the session, and the timer that sends batches. Nothing here
/// throws into the app; when LoggerAI can't be reached, data is dropped.
class Client with WidgetsBindingObserver {
  Client(this.options) : enabled = options.enabled && options.publicKey.startsWith('pk_') {
    if (options.enabled && !options.publicKey.startsWith('pk_')) {
      debugPrint('LoggerAI: apps use the public key (pk_live_...), never the secret one. Not sending.');
    }
    _endpoint = Uri.tryParse(options.endpoint);
    _reportEndpoint = Uri.tryParse(options.reportEndpoint ?? options.endpoint.replaceFirst(RegExp(r'/batch/?$'), '/report'));
    _newSession();
  }

  final LoggerAIOptions options;
  bool enabled;
  Uri? _endpoint;
  Uri? _reportEndpoint;

  /// A call to LoggerAI itself, which is never recorded.
  bool isEndpoint(Uri url) => [_endpoint, _reportEndpoint].any((e) => e != null && url.host == e.host && url.port == e.port && url.path == e.path);
  final http.Client _http = http.Client();
  final List<Map<String, Object?>> _events = [];
  final List<Map<String, Object?>> _errors = [];
  Timer? _timer;
  Future<void>? _sending;
  DateTime? _backgroundSince;
  String? lastError;

  late String sessionId;
  late double _sessionStart;
  bool _sessionSent = false;
  String? screen;
  String? user;

  void start() {
    if (!enabled) return;
    _timer ??= Timer.periodic(options.flushInterval, (_) => flush());
    WidgetsBinding.instance.addObserver(this);
    if (options.captureNetwork) platform.captureNetwork(this);
  }

  void _newSession() {
    sessionId = uuid4();
    _sessionStart = _now();
    _sessionSent = false;
  }

  // ---- recording ---------------------------------------------------------------------------

  void event(String type, Map<String, Object?> payload) {
    if (!enabled) return;
    _events.add({'session_id': sessionId, 'ts': _now(), 'type': type, 'payload': redact(payload)});
    if (_events.length > _maxEvents) _events.removeRange(0, _events.length - _maxEvents);
  }

  void error(Object error, StackTrace? stack, {bool handled = false, Map<String, Object?>? context, String? source}) {
    if (!enabled) return;
    final type = error.runtimeType.toString();
    final message = redactString(error.toString().replaceFirst('$type: ', '').replaceFirst('Exception: ', ''));
    final fr = frames(stack, options.appPackages);
    _errors.add({
      'ts': _now(),
      'type': type,
      'message': message.length > 1000 ? message.substring(0, 1000) : message,
      'handled': handled,
      'route': screen,
      'method': kIsWeb ? 'BROWSER' : 'MOBILE',
      'status': null,
      'frames': fr,
      'context': redact({...?context, 'session_id': sessionId, if (source != null) 'source': source}),
    });
    if (_errors.length > _maxErrors) _errors.removeAt(0);
    final top = fr.cast<Map<String, Object?>?>().firstWhere((f) => f!['in_app'] == true, orElse: () => fr.isEmpty ? null : fr.first);
    event('app_error', {
      'message': '$type: ${message.length > 500 ? message.substring(0, 500) : message}',
      'source': top == null ? source : '${top['file']}:${top['line']}',
      'handled': handled,
    });
    if (!handled) flush(); // a crash may be the last thing this app does
  }

  // ---- the session -------------------------------------------------------------------------------

  Map<String, Object?> _session() {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    final size = view == null ? null : view.physicalSize / view.devicePixelRatio;
    final shortest = size == null ? 0 : min(size.width, size.height);
    final os = platform.osName();
    final desktop = const {'macos', 'windows', 'linux'}.contains(os.split(' ').first);
    return {
      'id': sessionId,
      'started_at': _sessionStart,
      'ended_at': null,
      'page': screen,
      'browser': 'Flutter app${options.release != null ? ' ${options.release}' : ''}',
      'os': os,
      'device': kIsWeb ? 'web' : desktop ? 'desktop' : shortest >= 600 ? 'tablet' : 'mobile',
      'screen': size == null ? null : [size.width.round(), size.height.round()],
      'user': user,
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundSince ??= DateTime.now();
    }
    if (state == AppLifecycleState.resumed && _backgroundSince != null) {
      if (DateTime.now().difference(_backgroundSince!) > options.sessionTimeout) _newSession();
      _backgroundSince = null;
    }
    if (state != AppLifecycleState.inactive) event('app_lifecycle', {'state': state.name});
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) flush();
  }

  // ---- sending ------------------------------------------------------------------------------------

  /// Sends what's waiting. Safe to call any time.
  Future<void> flush() {
    if (!enabled) return Future.value();
    return _sending ??= _send().whenComplete(() => _sending = null);
  }

  Future<void> _send() async {
    if (_events.isEmpty && _errors.isEmpty) return;
    final events = List.of(_events.take(_maxEvents));
    final errors = List.of(_errors);
    final withSession = !_sessionSent;
    final body = jsonEncode({
      'sdk': {'name': 'loggerai-flutter', 'version': sdkVersion},
      'service': options.service,
      'environment': options.environment,
      'release': options.release,
      'host': platform.osName(),
      if (withSession) 'sessions': [_session()],
      'events': events,
      'errors': errors,
    });
    try {
      final r = await _http
          .post(Uri.parse(options.endpoint), headers: {'Content-Type': 'application/json', 'X-LoggerAI-Key': options.publicKey}, body: body)
          .timeout(const Duration(seconds: 10));
      if (r.statusCode == 401 || r.statusCode == 403) {
        enabled = false; // a wrong key won't start working by retrying
        debugPrint('LoggerAI: the key was refused (${r.statusCode}). Check the public key; sending stopped.');
      }
      lastError = r.statusCode < 300 ? null : 'LoggerAI answered ${r.statusCode}';
      if (r.statusCode < 500 && r.statusCode != 429) {
        _events.removeRange(0, min(events.length, _events.length));
        _errors.removeRange(0, min(errors.length, _errors.length));
        if (withSession && r.statusCode < 300) _sessionSent = true;
      }
    } catch (e) {
      lastError = "couldn't reach LoggerAI: $e"; // kept for the next try, within the buffer's limits
    }
  }

  // ---- reports ------------------------------------------------------------------------------------

  /// Sends a problem the user reported, with what they did before it. Returns the issue's id.
  Future<int> report(String note, {Uint8List? screenshot, Uint8List? recording, String? contact, Map<String, Object?>? extra}) async {
    final url = _reportEndpoint;
    if (!enabled || url == null) throw LoggerAIReportException('Reporting is switched off in this app.');
    event('custom_event', {'name': 'issue_reported', 'note': note, 'screen': screen});
    await flush(); // the session and its steps first, so the issue links to them
    final s = _session();
    final req = http.MultipartRequest('POST', url)
      ..headers['X-LoggerAI-Key'] = options.publicKey
      ..fields['report'] = jsonEncode({
        'session_id': sessionId,
        'note': redactString(note),
        'screen': screen,
        'user': user,
        if (contact != null && contact.trim().isNotEmpty) 'contact': contact.trim(),
        'platform': kIsWeb ? 'browser' : 'flutter',
        'device': '${s['device']} · ${s['os']}',
        'release': options.release,
        'environment': options.environment,
        'service': options.service,
        if (extra != null) 'extra': redact(extra),
      });
    if (screenshot != null) req.files.add(http.MultipartFile.fromBytes('screenshot', screenshot, filename: 'screenshot.png'));
    if (recording != null) req.files.add(http.MultipartFile.fromBytes('recording', recording, filename: 'recording.lrec'));
    final http.Response r;
    try {
      r = await http.Response.fromStream(await _http.send(req).timeout(const Duration(seconds: 60)));
    } catch (e) {
      throw LoggerAIReportException("Couldn't send the report. Check your connection and try again.");
    }
    if (r.statusCode == 201) {
      try {
        return (jsonDecode(r.body) as Map)['id'] as int;
      } catch (_) {
        return 0;
      }
    }
    if (r.statusCode == 429) throw LoggerAIReportException('Too many reports right now. Try again in a little while.');
    if (r.statusCode == 413) throw LoggerAIReportException('The recording is too long to send. Record a shorter one.');
    throw LoggerAIReportException("Couldn't send the report (${r.statusCode}).");
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _http.close();
  }
}
