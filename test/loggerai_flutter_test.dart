import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loggerai_flutter/loggerai_flutter.dart';
import 'package:loggerai_flutter/src/frames.dart';

/// A stand-in for LoggerAI's ingest (and an API the app calls), on a real socket.
class Fake {
  late HttpServer server;
  final batches = <Map<String, dynamic>>[];
  final keys = <String?>[];
  final apiHeaders = <HttpHeaders>[];

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/ingest') {
        batches.add(jsonDecode(body) as Map<String, dynamic>);
        keys.add(req.headers.value('x-loggerai-key'));
        req.response.statusCode = 202;
      } else {
        apiHeaders.add(req.headers);
        req.response.statusCode = req.uri.path == '/down' ? 503 : 200;
        req.response.write('{"ok":true}');
      }
      await req.response.close();
    });
  }

  String get ingest => 'http://127.0.0.1:${server.port}/ingest';
  String api(String path) => 'http://127.0.0.1:${server.port}$path';
  List<dynamic> all(String kind) => batches.expand((b) => (b[kind] as List?) ?? const []).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fake = Fake();

  setUpAll(() async {
    HttpOverrides.global = null; // flutter_test fakes HTTP; these tests use a real local server
    await fake.start();
  });
  // flutter_test puts its fake HTTP back before each test (its requests never complete).
  setUp(() => HttpOverrides.global = null);
  tearDownAll(() => fake.server.close(force: true));

  LoggerAIOptions opts() => LoggerAIOptions(
        publicKey: 'pk_live_test',
        endpoint: fake.ingest,
        service: 'mobile',
        release: '1.4.2',
        appPackages: const ['shop'],
        traceHosts: const ['127.0.0.1'],
        flushInterval: const Duration(minutes: 5),
      );

  test('errors, screens and events go out in one session', () async {
    LoggerAI.init(opts());
    LoggerAI.setScreen('/cart');
    LoggerAI.setUser('u-42');
    try {
      throw StateError('Cart total went negative, token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U');
    } catch (e, s) {
      LoggerAI.captureException(e, s, {'password': 'hunter2', 'basket': 3});
    }
    LoggerAI.event('coupon_applied', {'code': 'SAVE10'});
    await LoggerAI.flush();
    final b = fake.batches.last;
    expect(fake.keys.last, 'pk_live_test');
    expect(b['sdk'], {'name': 'loggerai-flutter', 'version': '0.1.0'});
    expect(b['service'], 'mobile');
    expect(b['release'], '1.4.2');
    final session = (b['sessions'] as List).single as Map;
    expect(session['id'], LoggerAI.sessionId);
    expect(session['user'], 'u-42');
    expect(session['browser'], 'Flutter app 1.4.2');
    final err = (b['errors'] as List).single as Map;
    expect(err['type'], 'StateError');
    expect(err['method'], 'MOBILE');
    expect(err['route'], '/cart');
    expect(err['handled'], true);
    expect(err['message'], contains('[REDACTED_JWT]'));
    expect((err['context'] as Map)['password'], '[REDACTED]');
    expect((err['frames'] as List).first['file'], contains('loggerai_flutter_test.dart'));
    final types = (b['events'] as List).map((e) => e['type']).toList();
    expect(types, containsAll(['page_view', 'app_error', 'custom_event']));
    final coupon = (b['events'] as List).firstWhere((e) => e['type'] == 'custom_event')['payload'] as Map;
    expect(coupon['code'], 'SAVE10', reason: '"code" is a secret only as a URL parameter, not as a field');
  });

  test('network calls are timed, and calls to your API carry trace headers', () async {
    LoggerAI.init(opts());
    final sid = LoggerAI.sessionId;
    await http.get(Uri.parse(fake.api('/orders/7?token=abc&page=2')));
    await http.get(Uri.parse(fake.api('/down')));
    await LoggerAI.flush();
    final net = fake.all('events').where((e) => e['type'] == 'network_request').map((e) => e['payload'] as Map).toList();
    final ok = net.firstWhere((p) => (p['url'] as String).contains('/orders/7'));
    expect(ok['status'], 200);
    expect(ok['method'], 'GET');
    expect(ok['url'], contains('page=2'));
    expect(ok['url'], isNot(contains('token=abc')));
    expect(ok['duration_ms'], greaterThan(0));
    expect(net.any((p) => p['status'] == 503), isTrue);
    expect(fake.apiHeaders.last.value('x-loggerai-session'), sid);
    expect(fake.apiHeaders.last.value('traceparent'), matches(RegExp(r'^00-[0-9a-f]{32}-[0-9a-f]{16}-01$')));
    expect(ok['trace_id'], hasLength(32));
    expect(net.any((p) => (p['url'] as String).contains('/ingest')), isFalse, reason: 'sending to LoggerAI is never recorded');
  });

  test('uncaught async errors in LoggerAI.run are reported as crashes', () async {
    final before = fake.all('errors').length;
    await LoggerAI.run(opts(), () {
      Future<void>.delayed(const Duration(milliseconds: 5), () => throw const FormatException('Bad price "12,50"'));
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await LoggerAI.flush();
    final crash = fake.all('errors').skip(before).firstWhere((e) => e['type'] == 'FormatException') as Map;
    expect(crash['handled'], false);
    expect((crash['context'] as Map)['source'], 'zone');
  });

  test('stack frames: the app first, libraries marked', () {
    final stack = StackTrace.fromString('#0      CartScreen._checkout (package:shop/screens/cart.dart:42:7)\n'
        '#1      _rootRunUnary (dart:async/zone.dart:1415:13)\n'
        '#2      State.setState (package:flutter/src/widgets/framework.dart:1199:30)\n'
        '<asynchronous suspension>\n'
        'package:shop/api.dart 18:3  Api.load\n');
    final f = frames(stack, const []);
    expect(f[0], {'file': 'package:shop/screens/cart.dart', 'line': 42, 'function': '_checkout', 'class': 'CartScreen', 'in_app': true});
    expect(f[1]['in_app'], false);
    expect(f[2]['in_app'], false);
    expect(f[3]['file'], 'package:shop/api.dart');
    expect(f[3]['line'], 18);
  });

  test('redaction', () {
    expect(isSensitive('accessToken'), isTrue);
    expect(isSensitive('X-Api-Key'), isTrue);
    expect(isSensitive('page'), isFalse);
    expect(redactUrl('https://u:pw@a.b/c?key=k&page=2'), allOf(contains('page=2'), isNot(contains('key=k')), isNot(contains('pw'))));
    expect(redactString('Authorization: Bearer abcdefghijklmnop1234'), 'Authorization: Bearer [REDACTED]');
  });

  test('a secret key is refused: apps ship the public key', () {
    final c = LoggerAI.init(LoggerAIOptions(publicKey: 'sk_live_oops', endpoint: fake.ingest));
    expect(c.enabled, isFalse);
  });

  testWidgets('the navigator observer names screens; the report sheet sends a note', (tester) async {
    await tester.runAsync(() async => LoggerAI.init(opts()));
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [LoggerAI.navigatorObserver],
      routes: {
        '/': (c) => Scaffold(body: Center(child: ElevatedButton(onPressed: () => Navigator.of(c).pushNamed('/settings'), child: const Text('go')))),
        '/settings': (c) => Scaffold(body: Center(child: ElevatedButton(onPressed: () => LoggerAI.showReportSheet(c), child: const Text('report')))),
      },
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(LoggerAI.client!.screen, '/settings');
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('loggerai-report-text')), 'The pay button does nothing');
    await tester.runAsync(() async {
      await tester.tap(find.byKey(const Key('loggerai-report-send')));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('Thanks'), findsOneWidget);
    final report = fake.all('events').lastWhere((e) => e['type'] == 'custom_event')['payload'] as Map;
    expect(report['name'], 'issue_reported');
    expect(report['note'], 'The pay button does nothing');
    expect(report['screen'], '/settings');
    final views = fake.all('events').where((e) => e['type'] == 'page_view').map((e) => (e['payload'] as Map)['url']).toList();
    expect(views, containsAll(['/', '/settings']));
  });
}
