import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:loggerai_flutter/loggerai_flutter.dart';
import 'package:loggerai_flutter/src/capture.dart';
import 'package:loggerai_flutter/src/client.dart' show sdkVersion;
import 'package:loggerai_flutter/src/frames.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A stand-in for LoggerAI's ingest (and an API the app calls), on a real socket.
class Fake {
  late HttpServer server;
  final batches = <Map<String, dynamic>>[];
  final keys = <String?>[];
  final apiHeaders = <HttpHeaders>[];
  final reports = <List<int>>[];
  final mine = <Map<String, dynamic>>[];
  // When set, a report's answer waits on it (to see the sheet mid-send).
  Future<void>? holdReports;
  int reportsWaiting = 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final List<int> raw;
      try {
        raw = await req.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
      } on HttpException {
        return; // the server closed at the end of the tests
      }
      final body = utf8.decode(raw, allowMalformed: true);
      if (req.uri.path == '/ingest/report') {
        final hold = holdReports;
        if (hold != null) {
          reportsWaiting++;
          await hold;
        }
        reports.add(raw);
        keys.add(req.headers.value('x-loggerai-key'));
        req.response.statusCode = 201;
        req.response.write('{"id": ${reports.length}}');
      } else if (req.uri.path == '/ingest/my-reports') {
        mine.add(jsonDecode(body) as Map<String, dynamic>);
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({
          'verified': true,
          'reports': [
            {'id': 12, 'title': 'Pay button does nothing', 'status': 'investigating', 'created_at': '2026-10-22T10:00:00', 'updated_at': null, 'resolved_at': null},
            {'id': 9, 'title': 'Map stays blank', 'status': 'resolved', 'created_at': '2026-10-20T09:00:00', 'updated_at': null, 'resolved_at': '2026-10-21T09:00:00'},
          ],
        }));
      } else if (req.uri.path == '/hcp/nearby-hcps') {
        // A failed call with a body that explains it.
        apiHeaders.add(req.headers);
        req.response.statusCode = 401;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'detail': 'Token expired', 'token': 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U'}));
      } else if (req.uri.path == '/emergency-contacts') {
        // A validation error that echoes what was sent, as FastAPI does.
        req.response.statusCode = 422;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'detail': [{'msg': 'phone is not valid', 'input': jsonDecode(body)}]}));
      } else if (req.uri.path == '/ingest/batch') {
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

  String get ingest => 'http://127.0.0.1:${server.port}/ingest/batch';
  String api(String path) => 'http://127.0.0.1:${server.port}$path';
  List<dynamic> all(String kind) => batches.expand((b) => (b[kind] as List?) ?? const []).toList();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fake = Fake();

  setUpAll(() async {
    HttpOverrides.global = null; // flutter_test fakes HTTP; these tests use a real local server
    SharedPreferences.setMockInitialValues({});
    await fake.start();
  });
  // flutter_test puts its fake HTTP back before each test (its requests never complete).
  setUp(() => HttpOverrides.global = null);
  tearDownAll(() => fake.server.close(force: true));

  LoggerAIOptions opts({List<String> maskKeys = const []}) => LoggerAIOptions(
        publicKey: 'pk_live_test',
        endpoint: fake.ingest,
        service: 'mobile',
        release: '1.4.2',
        appPackages: const ['shop'],
        traceHosts: const ['127.0.0.1'],
        flushInterval: const Duration(minutes: 5),
        maskKeys: maskKeys,
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
    expect(b['sdk'], {'name': 'loggerai-flutter', 'version': sdkVersion});
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

  test('personal details are never kept: phones, emails, addresses, postcodes, names, dates of birth', () {
    expect(
        redact({
          'phone': '08031234567', 'phone_number': '+2348031234567', 'contactPhone': 8031234567, 'email': 'ada@example.com',
          'emails': ['a@b.co'], 'static_address': '12 Allen Avenue, Ikeja', 'share_postcode': 'LA 15 A14 AV 11', 'first_name': 'Ada',
          'lastName': 'Obi', 'full_name': 'Ada Obi', 'date_of_birth': '1990-01-01', 'dob': '1990-01-01',
          // kept: flags about these, and ordinary fields
          'send_email': true, 'email_enabled': false, 'state_name': 'Lagos', 'name': 'issue_reported', 'page': 2,
        }),
        {
          'phone': '[REDACTED]', 'phone_number': '[REDACTED]', 'contactPhone': '[REDACTED]', 'email': '[REDACTED]',
          'emails': '[REDACTED]', 'static_address': '[REDACTED]', 'share_postcode': '[REDACTED]', 'first_name': '[REDACTED]',
          'lastName': '[REDACTED]', 'full_name': '[REDACTED]', 'date_of_birth': '[REDACTED]', 'dob': '[REDACTED]',
          'send_email': true, 'email_enabled': false, 'state_name': 'Lagos', 'name': 'issue_reported', 'page': 2,
        });
    expect(redactUrl('https://a.b/users?email=ada%40example.com&phone=0803&page=2'),
        allOf(contains('email=[REDACTED]'), contains('phone=[REDACTED]'), contains('page=2')));
    expect(redactString('Write to ada.obi@mail.example.ng or call +234 803 123 4567, or 0803 123 4567, or 08031234567'),
        'Write to [REDACTED_EMAIL] or call [REDACTED_PHONE], or [REDACTED_PHONE], or [REDACTED_PHONE]');
    // not phone numbers: ids, timestamps, versions, amounts
    expect(redactString('order 1729612345678 at 2026-10-23, v3.12.1, ₦08000.50 id 0803'), 'order 1729612345678 at 2026-10-23, v3.12.1, ₦08000.50 id 0803');
    expect(redact({'extra': {'Safety-ID': 'K7', 'safety_id': 'K7', 'other': 'x'}}, 0, {'safetyid'}), {
      'extra': {'Safety-ID': '[REDACTED]', 'safety_id': '[REDACTED]', 'other': 'x'}
    });
  });

  test('locations are never kept', () {
    final u = redactUrl('https://api.hospify.com/hcp/nearby-hcps?user_lat=6.524379&user_lon=3.379206&radius=5');
    expect(u, allOf(isNot(contains('6.524379')), isNot(contains('3.379206')), contains('radius=5')));
    expect(redact({'latitude': 6.5, 'userLng': 3.3, 'pickup_latitude': 1, 'coords': [1, 2], 'plate': 'kept'}),
        {'latitude': '[REDACTED]', 'userLng': '[REDACTED]', 'pickup_latitude': '[REDACTED]', 'coords': '[REDACTED]', 'plate': 'kept'});
    expect(redactString('/nearby/6.524379,3.379206'), '/nearby/[REDACTED_LOCATION]');
    expect(redactString('v1.2,3.4 and 2.0.1'), 'v1.2,3.4 and 2.0.1', reason: 'versions are not coordinates');
  });

  test('a secret key is refused: apps ship the public key', () {
    final c = LoggerAI.init(LoggerAIOptions(publicKey: 'sk_live_oops', endpoint: fake.ingest));
    expect(c.enabled, isFalse);
  });

  Map field(String body) {
    final m = RegExp(r'name="report"\r\n(?:[^\r\n]+\r\n)*\r\n(.*?)\r\n--', dotAll: true).firstMatch(body);
    if (m == null) throw StateError('no report field in: ${body.substring(0, body.length.clamp(0, 400))}');
    return jsonDecode(m.group(1)!) as Map;
  }

  test('report(): the note, the session, a screenshot and a recording in one request', () async {
    LoggerAI.init(opts());
    LoggerAI.setScreen('/checkout');
    final rec = encodeRecording([(0, Uint8List.fromList([1, 2, 3])), (500, Uint8List.fromList([4, 5]))], 10, 20);
    final id = await LoggerAI.report('Pay does nothing, password hunter2 token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U',
        screenshot: Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]), recording: rec, contact: 'ada@example.com');
    expect(id, fake.reports.length);
    final body = latin1.decode(fake.reports.last);
    final report = field(body);
    expect(report['session_id'], LoggerAI.sessionId);
    expect(report['screen'], '/checkout');
    expect(report['platform'], 'flutter');
    expect(report['contact'], 'ada@example.com');
    expect(report['note'], contains('[REDACTED_JWT]'));
    expect(body, contains('name="screenshot"'));
    expect(body, contains('name="recording"'));
    expect(body, contains('LREC'));
    expect(fake.keys.last, 'pk_live_test');
    // the session went first, so the issue can link to it; the report is in its timeline
    final ev = fake.all('events').lastWhere((e) => e['type'] == 'custom_event')['payload'] as Map;
    expect(ev['name'], 'issue_reported');
    final net = fake.all('events').where((e) => e['type'] == 'network_request').map((e) => (e['payload'] as Map)['url'] as String);
    expect(net.any((u) => u.contains('/ingest/')), isFalse, reason: 'calls to LoggerAI are never recorded');
  });

  test('report(): upload progress goes up in pieces to the whole body, and the recording arrives intact', () async {
    LoggerAI.init(opts());
    final big = Uint8List.fromList(List.generate(300 * 1024, (i) => i % 251));
    final seen = <(int, int)>[];
    await LoggerAI.report('Slow upload', recording: big, onProgress: (sent, total) => seen.add((sent, total)));
    final total = seen.first.$2;
    expect(total, greaterThan(big.length));
    expect(seen.first.$1, 0);
    expect(seen.last.$1, total);
    expect(seen.where((p) => p.$1 > 0 && p.$1 < total).length, greaterThanOrEqualTo(8), reason: 'sent in 32 KB pieces, not one jump');
    for (var i = 1; i < seen.length; i++) {
      expect(seen[i].$1, greaterThanOrEqualTo(seen[i - 1].$1));
    }
    final raw = fake.reports.last;
    expect(raw.length, total);
    final text = latin1.decode(raw);
    final start = text.indexOf('\r\n\r\n', text.indexOf('filename="recording.lrec"')) + 4;
    expect(raw.sublist(start, start + big.length), big);
  });

  testWidgets('the report sheet shows the upload while it sends', (tester) async {
    await tester.runAsync(() async => LoggerAI.init(opts()));
    final gate = Completer<void>();
    fake.holdReports = gate.future;
    fake.reportsWaiting = 0;
    addTearDown(() => fake.holdReports = null);
    await tester.pumpWidget(MaterialApp(
        home: Builder(
            builder: (c) => Scaffold(
                body: Center(
                    child: ElevatedButton(
                        onPressed: () => LoggerAI.showReportSheet(c, allowRecording: false, allowScreenshots: false), child: const Text('report')))))));
    Future<void> real(int ms) => tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));

    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('loggerai-report-text')), 'It hangs');
    await tester.tap(find.byKey(const Key('loggerai-report-send')));
    await tester.pump();
    expect(find.byKey(const Key('loggerai-report-progress')), findsOneWidget);
    expect(find.text('Sending…'), findsOneWidget);

    // the body is all sent; the server hasn't answered yet
    for (var i = 0; i < 40 && fake.reportsWaiting == 0; i++) {
      await real(50);
      await tester.pump();
    }
    await real(50);
    await tester.pump();
    expect(find.text('Almost done…'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(find.byKey(const Key('loggerai-report-progress')));
    expect(bar.value, 1.0);

    gate.complete();
    for (var i = 0; i < 40 && find.byKey(const Key('loggerai-report-sent')).evaluate().isEmpty; i++) {
      await real(50);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('The team has your report'), findsOneWidget);
    expect(find.textContaining("They'll look into it and get back to you"), findsOneWidget);
    expect(find.textContaining('Report #'), findsOneWidget);
    expect(find.byKey(const Key('loggerai-report-see-mine')), findsOneWidget);
    expect(find.byKey(const Key('loggerai-report-progress')), findsNothing);
    await tester.pump(const Duration(seconds: 16)); // dart:io's keep-alive timer for the connection
  });

  test('the recording format', () {
    final f = encodeRecording([(0, Uint8List.fromList([9, 9, 9])), (480, Uint8List.fromList([7]))], 360, 780);
    expect(ascii.decode(f.sublist(0, 4)), 'LREC');
    final n = ByteData.sublistView(f, 4, 8).getUint32(0);
    final head = jsonDecode(utf8.decode(f.sublist(8, 8 + n))) as Map;
    expect(head['width'], 360);
    expect(head['frames'], [
      {'t': 0, 'o': 0, 'n': 3},
      {'t': 480, 'o': 3, 'n': 1},
    ]);
    expect(f.sublist(8 + n), [9, 9, 9, 7]);
  });

  testWidgets('screenshots paint over text fields and LoggerAIMask', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        backgroundColor: Color(0xFFFF0000),
        body: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(height: 100),
          SizedBox(width: 300, child: TextField(controller: null, decoration: InputDecoration(border: InputBorder.none))),
          SizedBox(height: 50),
          LoggerAIMask(child: SizedBox(width: 200, height: 40, child: ColoredBox(color: Color(0xFF00FF00)))),
        ]),
      ),
    ));
    await tester.enterText(find.byType(TextField), 'my secret password');
    await tester.pump();
    await tester.runAsync(() async {
      final img = (await captureScreen(maxWidth: 800))!;
      final px = (await img.toByteData())!;
      int at(Offset o) => px.getUint32((o.dy.round() * img.width + o.dx.round()) * 4);
      final field = tester.getRect(find.byType(EditableText)).center;
      final masked = tester.getRect(find.byType(LoggerAIMask)).center;
      expect(at(field), 0x9AA3ADFF, reason: 'the text field is covered');
      expect(at(masked), 0x9AA3ADFF, reason: 'LoggerAIMask is covered');
      expect(at(const Offset(5, 5)), 0xFF0000FF, reason: 'the rest of the screen is kept');
      expect(img.width, 800);
    });
  });

  testWidgets('the report sheet: screenshots when the user asks, a recording with a running clock, and the note', (tester) async {
    await tester.runAsync(() async => LoggerAI.init(opts()));
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [LoggerAI.navigatorObserver],
      routes: {
        '/': (c) => Scaffold(body: Center(child: ElevatedButton(onPressed: () => Navigator.of(c).pushNamed('/settings'), child: const Text('go')))),
        '/settings': (c) => Scaffold(
            backgroundColor: Colors.amber,
            body: Center(child: ElevatedButton(onPressed: () => LoggerAI.showReportSheet(c, askContact: true), child: const Text('report')))),
      },
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(LoggerAI.client!.screen, '/settings');

    Future<void> real(int ms) => tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    Future<void> settle([int n = 20]) async {
      for (var i = 0; i < n; i++) {
        await real(30);
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    await tester.tap(find.text('report'));
    await settle();
    expect(find.textContaining('Screenshot'), findsNothing, reason: 'no picture is taken until the user asks');
    await tester.enterText(find.byKey(const Key('loggerai-report-text')), 'The pay button does nothing');
    await tester.enterText(find.byKey(const Key('loggerai-report-contact')), 'ada@example.com');

    // A screenshot from the sheet: it closes, the screen is taken, it comes back.
    await tester.tap(find.byKey(const Key('loggerai-report-screenshot')));
    await settle();
    expect(find.text('Screenshot'), findsOneWidget);
    expect(find.text('The pay button does nothing'), findsOneWidget, reason: 'what they typed is kept');

    await tester.tap(find.byKey(const Key('loggerai-report-record')));
    await settle();
    expect(find.byKey(const Key('loggerai-record-stop')), findsOneWidget, reason: 'the sheet hides and the Stop pill shows');
    String clock() => tester.widget<Text>(find.byKey(const Key('loggerai-record-clock'))).data!;
    final first = clock();
    await real(1300);
    await tester.pump(const Duration(milliseconds: 300));
    expect(clock(), isNot(first), reason: 'the clock keeps moving');
    // A screenshot from the recording bar.
    await tester.tap(find.byKey(const Key('loggerai-record-screenshot')));
    await settle(8);
    await tester.tap(find.byKey(const Key('loggerai-record-stop')));
    await settle();
    expect(find.byKey(const Key('loggerai-record-stop')), findsNothing);
    expect(find.textContaining('Recording 0:0'), findsOneWidget, reason: 'the sheet is back with the recording');
    expect(find.text('Screenshot 1'), findsOneWidget);
    expect(find.text('Screenshot 2'), findsOneWidget);

    await tester.tap(find.byKey(const Key('loggerai-report-send')));
    for (var i = 0; i < 30 && find.byKey(const Key('loggerai-report-sent')).evaluate().isEmpty; i++) {
      await real(100);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('The team has your report'), findsOneWidget);
    expect(find.textContaining('2 screenshots and the recording'), findsOneWidget);
    expect(find.textContaining('at ada@example.com'), findsOneWidget);
    final body = latin1.decode(fake.reports.last);
    final report = field(body);
    expect(report['note'], 'The pay button does nothing');
    expect(report['screen'], '/settings');
    expect(report['contact'], 'ada@example.com');
    expect(report['reporter'], matches(RegExp(r'^[0-9a-f-]{36}$')), reason: 'the device id, for My reports');
    expect(RegExp('name="screenshot"').allMatches(body).length, 2);
    final rec = fake.reports.last;
    final at = latin1.decode(rec).indexOf('LREC');
    expect(at, greaterThan(0));
    final n = ByteData.sublistView(Uint8List.fromList(rec), at + 4, at + 8).getUint32(0);
    final head = jsonDecode(utf8.decode(rec.sublist(at + 8, at + 8 + n))) as Map;
    expect((head['frames'] as List).length, greaterThanOrEqualTo(2));
    LoggerAI.client!.close(); // its idle connections, before the test's fake clock checks for timers
  });

  test('a failed call carries its headers and bodies, masked; a successful one stays short', () async {
    LoggerAI.init(opts());
    await http.post(Uri.parse(fake.api('/hcp/nearby-hcps?radius_km=10.0&user_lat=6.524379&user_lon=3.379206')),
        headers: {'Authorization': 'Bearer abcdefghijklmnopqrstuvwxyz', 'Content-Type': 'application/json'},
        body: jsonEncode({'password': 'hunter2', 'page': 1}));
    await http.get(Uri.parse(fake.api('/orders/9')));
    await LoggerAI.flush();
    final net = fake.all('events').where((e) => e['type'] == 'network_request').map((e) => e['payload'] as Map).toList();
    final bad = net.lastWhere((p) => (p['url'] as String).contains('/hcp/nearby-hcps'));
    expect(bad['status'], 401);
    expect(bad['url'], allOf(contains('radius_km=10.0'), isNot(contains('6.524379')), isNot(contains('3.379206'))));
    expect((bad['response_data'] as Map)['detail'], 'Token expired');
    expect((bad['response_data'] as Map)['token'], '[REDACTED]');
    expect((bad['request_payload'] as Map)['password'], '[REDACTED]');
    expect((bad['request_payload'] as Map)['page'], 1);
    final reqHeaders = (bad['request_headers'] as Map).map((k, v) => MapEntry('$k'.toLowerCase(), v));
    expect(reqHeaders['authorization'], '[REDACTED]');
    expect((bad['response_headers'] as Map).keys.map((k) => '$k'.toLowerCase()), contains('content-type'));
    final ok = net.lastWhere((p) => (p['url'] as String).contains('/orders/9'));
    expect(ok['status'], 200);
    expect(ok.containsKey('response_data'), isFalse);
    expect(ok.containsKey('request_headers'), isFalse);
  });

  test("a failed call's body: personal details and the app's maskKeys are masked, the error is kept", () async {
    LoggerAI.init(opts(maskKeys: const ['name', 'safety_id']));
    LoggerAI.event('contact_saved', {'relationship': 'Mother'});
    await http.post(Uri.parse(fake.api('/emergency-contacts')),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': 'Mum', 'phone': '08031234567', 'relationship': 'Mother', 'safety_id': 'LA 15 A14 AV 11 · K7'}));
    await LoggerAI.flush();
    final bad = fake.all('events').where((e) => e['type'] == 'network_request').map((e) => e['payload'] as Map).lastWhere((p) => (p['url'] as String).contains('/emergency-contacts'));
    expect(bad['status'], 422);
    expect(bad['request_payload'], {'name': '[REDACTED]', 'phone': '[REDACTED]', 'relationship': 'Mother', 'safety_id': '[REDACTED]'});
    final detail = ((bad['response_data'] as Map)['detail'] as List).first as Map;
    expect(detail['msg'], 'phone is not valid');
    expect(detail['input'], {'name': '[REDACTED]', 'phone': '[REDACTED]', 'relationship': 'Mother', 'safety_id': '[REDACTED]'});
    expect(jsonEncode(bad), allOf(isNot(contains('Mum')), isNot(contains('0803')), isNot(contains('K7'))));
    // maskKeys are for the app's network calls: the SDK's own events keep their names
    final ev = fake.all('events').where((e) => e['type'] == 'custom_event').map((e) => e['payload'] as Map).toList();
    expect(ev.map((p) => p['name']), contains('contact_saved'));
    expect(ev.every((p) => p['name'] != '[REDACTED]'), isTrue);
  });

  test('my reports: the device id and the signed user go with the question', () async {
    LoggerAI.init(opts());
    LoggerAI.setUser('u-42', hash: 'a' * 64);
    final list = await LoggerAI.myReports();
    final asked = fake.mine.last;
    expect(asked['user'], 'u-42');
    expect(asked['user_hash'], 'a' * 64);
    expect(asked['reporter'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    final again = await LoggerAI.myReports();
    expect(fake.mine.last['reporter'], asked['reporter'], reason: 'the same device id every time');
    expect(again.length, 2);
    expect(list.first.id, 12);
    expect(list.first.status, 'investigating');
    expect(list.last.resolved, isTrue);
    expect(list.last.resolvedAt, isNotNull);
  });

  testWidgets('the My reports sheet: open and resolved', (tester) async {
    await tester.runAsync(() async => LoggerAI.init(opts()));
    await tester.pumpWidget(MaterialApp(
        home: Builder(builder: (c) => Scaffold(body: Center(child: ElevatedButton(onPressed: () => LoggerAI.showMyReportsSheet(c), child: const Text('mine')))))));
    Future<void> real(int ms) => tester.runAsync(() => Future<void>.delayed(Duration(milliseconds: ms)));
    await tester.tap(find.text('mine'));
    for (var i = 0; i < 30 && find.text('Pay button does nothing').evaluate().isEmpty; i++) {
      await real(50);
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.text('Pay button does nothing'), findsOneWidget);
    expect(find.text('Being looked at'), findsOneWidget);
    expect(find.text('Map stays blank'), findsNothing, reason: 'resolved ones are on the other tab');
    await tester.tap(find.text('Resolved'));
    await tester.pumpAndSettle();
    expect(find.text('Map stays blank'), findsOneWidget);
    expect(find.textContaining('Report #9'), findsOneWidget);
    LoggerAI.client!.close();
    await tester.pump(const Duration(seconds: 16));
  });
}
