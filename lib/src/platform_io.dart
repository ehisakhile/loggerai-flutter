// Android, iOS and desktop: the OS version, and every HTTP call the app makes
// (package:http, Dio and HttpClient all go through dart:io's HttpClient).
import 'dart:io';

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

/// Times each request until its response headers arrive, and adds trace headers
/// for the app's own API.
class _TimedClient implements HttpClient {
  _TimedClient(this._inner);

  final HttpClient _inner;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    final client = _active;
    if (client == null) return _inner.openUrl(method, url);
    return _open(client, method, url);
  }

  Future<HttpClientRequest> _open(Client client, String method, Uri url) async {
    if (!client.enabled || client.isEndpoint(url)) return _inner.openUrl(method, url);
    final started = DateTime.now();
    final traceId = hex(16);
    try {
      final req = await _inner.openUrl(method, url);
      if (client.options.traceHosts.contains(url.host)) {
        req.headers.set('traceparent', '00-$traceId-${hex(8)}-01');
        req.headers.set('x-loggerai-session', client.sessionId);
      }
      req.done.then((res) => _record(client, method, url, started, res.statusCode, traceId),
          onError: (Object e) => _record(client, method, url, started, 0, traceId, e));
      return req;
    } catch (e) {
      _record(client, method, url, started, 0, traceId, e);
      rethrow;
    }
  }

  void _record(Client client, String method, Uri url, DateTime started, int status, String traceId, [Object? error]) {
    client.event('network_request', {
      'method': method.toUpperCase(),
      'url': url.toString(),
      'status': status == 0 ? null : status,
      'duration_ms': DateTime.now().difference(started).inMicroseconds / 1000,
      if (client.options.traceHosts.contains(url.host)) 'trace_id': traceId,
      if (error != null) 'error': error.toString(),
      'screen': client.screen,
    });
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
