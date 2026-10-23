// Android, iOS and desktop: the OS version, and every HTTP call the app makes
// (package:http, Dio and HttpClient all go through dart:io's HttpClient).
//
// Each call is timed until its response arrives. For a failed one (400 and up,
// or no answer) the headers, the request body and the response body come too,
// masked like everything else and cut to a few KB, so the team can see why it
// failed. Successful calls send only the method, address, status and time.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'client.dart';

String osName() {
  final v = Platform.operatingSystemVersion;
  // "Version 17.2 (Build 21C62)" or "TP1A.220624.014": keep it short
  final m = RegExp(r'(\d+(?:\.\d+)*)').firstMatch(v);
  return m == null ? Platform.operatingSystem : '${Platform.operatingSystem} ${m.group(1)}';
}

/// The client calls are recorded for: the latest one, after a second init too.
Client? _active;

void captureNetwork(Client client) {
  _active = client;
  if (HttpOverrides.current is _Overrides) return;
  HttpOverrides.global = _Overrides(HttpOverrides.current);
}

class _Overrides extends HttpOverrides {
  _Overrides(this.previous);

  final HttpOverrides? previous;

  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final inner = previous?.createHttpClient(context) ?? super.createHttpClient(context);
    return _TimedClient(inner);
  }
}

/// How long to wait for the app to read a failed response's body before sending what's known.
const _bodyWait = Duration(seconds: 5);

/// One call, from opening it to its response: collects what to send and sends it once.
class _Call {
  _Call(this.client, this.method, this.url) : traced = client.options.traceHosts.contains(url.host);

  final Client client;
  final String method;
  final Uri url;
  final bool traced;
  final started = DateTime.now();
  final traceId = hex(16);
  final requestBody = _Capped(maxBody);
  final responseBody = _Capped(maxBody);
  Map<String, String>? requestHeaders;
  Map<String, String>? responseHeaders;
  String? requestType;
  String? responseType;
  int status = 0;
  double? ms;
  bool _sent = false;
  Timer? _wait;

  static int get maxBody => _active?.options.maxBodyBytes ?? 4096;

  bool get failed => status == 0 || status >= 400;
  bool get details => switch (client.options.networkDetails) {
        NetworkDetails.none => false,
        NetworkDetails.failures => failed,
        NetworkDetails.all => true,
      };

  void responded(HttpClientResponse res) {
    status = res.statusCode;
    ms = DateTime.now().difference(started).inMicroseconds / 1000;
    responseHeaders = _headers(res.headers);
    responseType = res.headers.contentType?.mimeType;
    // Nothing more to wait for unless the body is wanted: send now. Otherwise give the app a moment to read it.
    if (!details) {
      send();
    } else {
      _wait = Timer(_bodyWait, send);
    }
  }

  void send([Object? error]) {
    if (_sent) return;
    _sent = true;
    _wait?.cancel();
    final p = <String, Object?>{
      'method': method.toUpperCase(),
      'url': url.toString(),
      'status': status == 0 ? null : status,
      'duration_ms': ms ?? DateTime.now().difference(started).inMicroseconds / 1000,
      if (traced) 'trace_id': traceId,
      if (error != null) 'error': error.toString(),
      'screen': client.screen,
    };
    if (details) {
      if (requestHeaders != null) p['request_headers'] = requestHeaders;
      if (requestBody.length > 0) p['request_payload'] = _body(requestBody, requestType);
      if (responseHeaders != null) p['response_headers'] = responseHeaders;
      if (responseBody.length > 0) p['response_data'] = _body(responseBody, responseType);
    }
    client.event('network_request', p); // event() masks secrets and locations in all of it
  }
}

Map<String, String> _headers(HttpHeaders h) {
  final out = <String, String>{};
  h.forEach((name, values) => out[name] = values.join(', '));
  return out;
}

/// Bytes kept up to a limit; the rest are only counted.
class _Capped {
  _Capped(this.limit);

  final int limit;
  final _b = BytesBuilder(copy: false);
  int length = 0;

  void add(List<int> data) {
    length += data.length;
    final room = limit - _b.length;
    if (room > 0) _b.add(data.length <= room ? data : data.sublist(0, room));
  }

  Uint8List get bytes => _b.toBytes();
  bool get truncated => length > _b.length;
}

const _textTypes = ['json', 'text', 'xml', 'x-www-form-urlencoded', 'javascript', 'graphql'];

/// A body for the timeline: JSON as JSON (so fields are masked by name), text as text, other things by size.
Object? _body(_Capped b, String? mime) {
  final type = (mime ?? '').toLowerCase();
  final bytes = b.bytes;
  final looksText = type.isEmpty ? !bytes.contains(0) : _textTypes.any(type.contains);
  if (!looksText) return '[${mime ?? 'binary'}, ${b.length} bytes]';
  final text = utf8.decode(bytes, allowMalformed: true);
  if (!b.truncated && (type.contains('json') || text.trimLeft().startsWith('{') || text.trimLeft().startsWith('['))) {
    try {
      return jsonDecode(text);
    } catch (_) {}
  }
  if (type.contains('x-www-form-urlencoded') && !b.truncated) {
    try {
      return Uri.splitQueryString(text);
    } catch (_) {}
  }
  return b.truncated ? '$text… [${b.length} bytes in all]' : text;
}

/// Times each request until its response arrives, and adds trace headers for the app's own API.
class _TimedClient implements HttpClient {
  _TimedClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final client = _active;
    if (client == null || !client.enabled || client.isEndpoint(url)) return _inner.openUrl(method, url);
    final call = _Call(client, method, url);
    try {
      final req = await _inner.openUrl(method, url);
      if (call.traced) {
        req.headers.set('traceparent', '00-${call.traceId}-${hex(8)}-01');
        req.headers.set('x-loggerai-session', client.sessionId);
      }
      return _LoggedRequest(req, call);
    } catch (e) {
      call.send(e);
      rethrow;
    }
  }

  @override
  Future<HttpClientRequest> open(String method, String host, int port, String path) =>
      openUrl(method, Uri(scheme: 'http', host: host, port: port, path: path));
  @override
  Future<HttpClientRequest> get(String host, int port, String path) => open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) => open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) => open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) => open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) => open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) => open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool v) => _inner.autoUncompress = v;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? v) => _inner.connectionTimeout = v;
  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration v) => _inner.idleTimeout = v;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? v) => _inner.maxConnectionsPerHost = v;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? v) => _inner.userAgent = v;
  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials credentials) => _inner.addCredentials(url, realm, credentials);
  @override
  void addProxyCredentials(String host, int port, String realm, HttpClientCredentials credentials) =>
      _inner.addProxyCredentials(host, port, realm, credentials);
  @override
  set authenticate(Future<bool> Function(Uri url, String scheme, String? realm)? f) => _inner.authenticate = f;
  @override
  set authenticateProxy(Future<bool> Function(String host, int port, String scheme, String? realm)? f) => _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(bool Function(X509Certificate cert, String host, int port)? callback) =>
      _inner.badCertificateCallback = callback;
  @override
  set connectionFactory(Future<ConnectionTask<Socket>> Function(Uri url, String? proxyHost, int? proxyPort)? f) =>
      _inner.connectionFactory = f;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;
}

/// The request as the app writes it: the body is copied (up to the limit) on its way out.
class _LoggedRequest implements HttpClientRequest {
  _LoggedRequest(this._inner, this._call);

  final HttpClientRequest _inner;
  final _Call _call;

  late final Future<HttpClientResponse> _response = _inner.done.then((res) {
    _call.responded(res);
    return _LoggedResponse(res, _call);
  }, onError: (Object e, StackTrace s) {
    _call.send(e);
    return Future<HttpClientResponse>.error(e, s);
  });

  void _headersOut() {
    _call.requestHeaders ??= _headers(_inner.headers);
    _call.requestType ??= _inner.headers.contentType?.mimeType;
  }

  @override
  Future<HttpClientResponse> close() {
    _headersOut();
    _inner.close().ignore(); // the same response as done, which _response follows
    return _response;
  }

  @override
  Future<HttpClientResponse> get done => _response;

  @override
  void add(List<int> data) {
    _headersOut();
    _call.requestBody.add(data);
    _inner.add(data);
  }

  @override
  Future addStream(Stream<List<int>> stream) {
    _headersOut();
    return _inner.addStream(stream.map((d) {
      _call.requestBody.add(d);
      return d;
    }));
  }

  @override
  void write(Object? object) {
    final s = '$object';
    add(encoding.encode(s));
  }

  @override
  void writeAll(Iterable objects, [String separator = '']) => write(objects.join(separator));
  @override
  void writeln([Object? object = '']) => write('$object\n');
  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));
  @override
  void addError(Object error, [StackTrace? stackTrace]) => _inner.addError(error, stackTrace);
  @override
  Future flush() => _inner.flush();
  @override
  void abort([Object? exception, StackTrace? stackTrace]) => _inner.abort(exception, stackTrace);

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding v) => _inner.encoding = v;
  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool v) => _inner.bufferOutput = v;
  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int v) => _inner.contentLength = v;
  @override
  bool get followRedirects => _inner.followRedirects;
  @override
  set followRedirects(bool v) => _inner.followRedirects = v;
  @override
  int get maxRedirects => _inner.maxRedirects;
  @override
  set maxRedirects(int v) => _inner.maxRedirects = v;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool v) => _inner.persistentConnection = v;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  String get method => _inner.method;
  @override
  Uri get uri => _inner.uri;
}

/// The response as the app reads it: for a failed call, the body is copied as it streams past.
class _LoggedResponse extends Stream<List<int>> implements HttpClientResponse {
  _LoggedResponse(this._inner, this._call);

  final HttpClientResponse _inner;
  final _Call _call;

  /// The body as the app reads it. The copy is made inside the stream, not in the listener: libraries
  /// such as Dio listen first (through cast()) and set their handlers afterwards, which would replace ours.
  late final Stream<List<int>> _body = !_call.details
      ? _inner
      : _inner.transform(StreamTransformer<List<int>, List<int>>.fromHandlers(
          handleData: (d, sink) {
            _call.responseBody.add(d);
            sink.add(d);
          },
          handleError: (Object e, StackTrace s, sink) {
            _call.send(e);
            sink.addError(e, s);
          },
          handleDone: (sink) {
            _call.send();
            sink.close();
          },
        ));

  @override
  StreamSubscription<List<int>> listen(void Function(List<int> event)? onData,
          {Function? onError, void Function()? onDone, bool? cancelOnError}) =>
      _body.listen(onData, onError: onError, onDone: onDone, cancelOnError: cancelOnError);

  @override
  int get statusCode => _inner.statusCode;
  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  int get contentLength => _inner.contentLength;
  @override
  HttpClientResponseCompressionState get compressionState => _inner.compressionState;
  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  bool get isRedirect => _inner.isRedirect;
  @override
  List<RedirectInfo> get redirects => _inner.redirects;
  @override
  Future<HttpClientResponse> redirect([String? method, Uri? url, bool? followLoops]) => _inner.redirect(method, url, followLoops);
  @override
  HttpHeaders get headers => _inner.headers;
  @override
  Future<Socket> detachSocket() => _inner.detachSocket();
  @override
  List<Cookie> get cookies => _inner.cookies;
  @override
  X509Certificate? get certificate => _inner.certificate;
  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
}
