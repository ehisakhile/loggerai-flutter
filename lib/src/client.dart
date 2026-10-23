import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'frames.dart';
import 'platform_stub.dart' if (dart.library.io) 'platform_io.dart' as platform;
import 'redact.dart';

const sdkVersion = '0.1.3';
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
    this.networkDetails = NetworkDetails.failures,
    this.maxBodyBytes = 4096,
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

  /// Which network calls carry their headers and bodies (masked, cut to [maxBodyBytes]).
  /// By default only failed ones (400 and up, or no answer), which is what explains a failure.
  final NetworkDetails networkDetails;
  final int maxBodyBytes;
}

/// How much of a network call is recorded besides its method, address, status and time.
enum NetworkDetails {
  /// Nothing more.
  none,

  /// Headers and bodies of failed calls: status 400 and up, or no answer.
  failures,

  /// Headers and bodies of every call.
  all,
}

/// A report the user sent, as they see it under "My reports".
class MyReport {
  MyReport({required this.id, required this.title, required this.status, required this.createdAt, this.updatedAt, this.resolvedAt});

  factory MyReport.fromJson(Map<String, Object?> j) => MyReport(
        id: (j['id'] as num).toInt(),
        title: '${j['title'] ?? ''}',
        status: '${j['status'] ?? 'open'}',
        createdAt: DateTime.tryParse('${j['created_at']}Z'.replaceFirst('ZZ', 'Z')) ?? DateTime.now(),
        updatedAt: j['updated_at'] == null ? null : DateTime.tryParse('${j['updated_at']}Z'.replaceFirst('ZZ', 'Z')),
        resolvedAt: j['resolved_at'] == null ? null : DateTime.tryParse('${j['resolved_at']}Z'.replaceFirst('ZZ', 'Z')),
      );

  final int id;
  final String title;

  /// open, investigating or resolved.
  final String status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final DateTime? resolvedAt;

  bool get resolved => status == 'resolved';
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

  /// The signature of [user] from your server, so LoggerAI shows this user their reports on any device.
  String? userHash;

  /// A random id kept on this device: the user's reports on this device, when they aren't signed in.
  String? _reporter;
  static const _reporterKey = 'loggerai.reporter';

  Future<String> reporterId() async {
    if (_reporter != null) return _reporter!;
    try {
      final prefs = await SharedPreferences.getInstance();
      _reporter = prefs.getString(_reporterKey);
      if (_reporter == null) {
        _reporter = uuid4();
        await prefs.setString(_reporterKey, _reporter!);
      }
    } catch (_) {
      _reporter ??= uuid4(); // no storage here: this run only
    }
    return _reporter!;
  }

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
  ///
  /// [onProgress] gets the bytes sent so far and the total as the upload goes.
  Future<int> report(String note,
      {Uint8List? screenshot,
      List<Uint8List> screenshots = const [],
      Uint8List? recording,
      String? contact,
      Map<String, Object?>? extra,
      void Function(int sent, int total)? onProgress}) async {
    final url = _reportEndpoint;
    if (!enabled || url == null) throw LoggerAIReportException('Reporting is switched off in this app.');
    event('custom_event', {'name': 'issue_reported', 'note': note, 'screen': screen});
    await flush(); // the session and its steps first, so the issue links to them
    final s = _session();
    final reporter = await reporterId();
    final req = http.MultipartRequest('POST', url)
      ..headers['X-LoggerAI-Key'] = options.publicKey
      ..fields['report'] = jsonEncode({
        'session_id': sessionId,
        'note': redactString(note),
        'screen': screen,
        'user': user,
        if (userHash != null) 'user_hash': userHash,
        'reporter': reporter,
        if (contact != null && contact.trim().isNotEmpty) 'contact': contact.trim(),
        'platform': kIsWeb ? 'browser' : 'flutter',
        'device': '${s['device']} · ${s['os']}',
        'release': options.release,
        'environment': options.environment,
        'service': options.service,
        if (extra != null) 'extra': redact(extra),
      });
    final shots = [if (screenshot != null) screenshot, ...screenshots].take(5).toList();
    for (final (i, shot) in shots.indexed) {
      req.files.add(http.MultipartFile.fromBytes('screenshot', shot, filename: 'screenshot-${i + 1}.png'));
    }
    if (recording != null) req.files.add(http.MultipartFile.fromBytes('recording', recording, filename: 'recording.lrec'));
    final http.Response r;
    try {
      r = await _sendCounted(req, onProgress);
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

  /// The reports this user sent: all of theirs when [userHash] proves who they are, otherwise
  /// the ones sent from this device. Newest first.
  Future<List<MyReport>> myReports() async {
    final base = _reportEndpoint;
    if (!enabled || base == null) throw LoggerAIReportException('Reporting is switched off in this app.');
    final url = base.replace(path: base.path.replaceFirst(RegExp(r'/report/?$'), '/my-reports'));
    final http.Response r;
    try {
      r = await _http
          .post(url,
              headers: {'Content-Type': 'application/json', 'X-LoggerAI-Key': options.publicKey},
              body: jsonEncode({'reporter': await reporterId(), if (user != null) 'user': user, if (userHash != null) 'user_hash': userHash}))
          .timeout(const Duration(seconds: 20));
    } catch (_) {
      throw LoggerAIReportException("Couldn't load your reports. Check your connection and try again.");
    }
    if (r.statusCode != 200) throw LoggerAIReportException("Couldn't load your reports (${r.statusCode}).");
    final items = (jsonDecode(r.body) as Map)['reports'] as List? ?? const [];
    return items.map((e) => MyReport.fromJson((e as Map).cast<String, Object?>())).toList();
  }

  /// Sends [req] in small pieces, counting each one as the connection takes it, so a
  /// recording on a slow network shows real progress. Gives up only when nothing has
  /// moved for [_stall], not after a fixed time, so a big upload on a slow line still
  /// gets through.
  static const _stall = Duration(seconds: 30);
  static const _piece = 32 * 1024;

  Future<http.Response> _sendCounted(http.MultipartRequest req, void Function(int sent, int total)? onProgress) async {
    final body = req.finalize(); // sets the multipart content-type header
    final total = req.contentLength;
    final out = http.StreamedRequest(req.method, req.url)
      ..headers.addAll(req.headers)
      ..contentLength = total;

    final stalled = Completer<Never>();
    Timer? watchdog;
    var finished = false; // the last piece can resume after the answer: no new watchdog then
    void kick() {
      if (finished) return;
      watchdog?.cancel();
      watchdog = Timer(_stall, () {
        if (!stalled.isCompleted) stalled.completeError(TimeoutException('upload stalled'));
      });
    }

    var sent = 0;
    onProgress?.call(0, total);
    kick();
    Stream<List<int>> pieces() async* {
      await for (final chunk in body) {
        for (var i = 0; i < chunk.length; i += _piece) {
          final part = chunk.sublist(i, min(i + _piece, chunk.length));
          yield part; // resumes only when the connection wants more
          sent += part.length;
          kick();
          onProgress?.call(sent, total);
        }
      }
    }

    unawaited(out.sink.addStream(pieces()).then((_) => out.sink.close(), onError: (Object e) => out.sink.close()));
    try {
      final streamed = await Future.any([_http.send(out), stalled.future]);
      finished = true;
      watchdog?.cancel();
      onProgress?.call(total, total);
      // The server is saving it: allow a moment, not the stall window again.
      return await http.Response.fromStream(streamed).timeout(const Duration(seconds: 60));
    } finally {
      finished = true;
      watchdog?.cancel();
    }
  }

  void close() {
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
    _http.close();
  }
}
