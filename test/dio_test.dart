// Dio goes through dart:io's HttpClient like package:http, but reads responses through
// cast() and sets its handlers after listening: failed calls must still keep their bodies.
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:loggerai_flutter/loggerai_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Dio: a failed call keeps its response body, masked; Dio still gets the whole answer', () async {
    HttpOverrides.global = null;
    SharedPreferences.setMockInitialValues({});
    final batches = <Map>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      if (req.uri.path == '/ingest/batch') {
        batches.add(jsonDecode(body) as Map);
        req.response.statusCode = 202;
      } else if (req.uri.path == '/ok') {
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"doctors":[]}');
      } else {
        req.response.statusCode = 401;
        req.response.headers.contentType = ContentType.json;
        req.response.write('{"detail":"Not authenticated","token":"abc"}');
      }
      await req.response.close();
    });
    LoggerAI.init(LoggerAIOptions(publicKey: 'pk_live_x', endpoint: 'http://127.0.0.1:${server.port}/ingest/batch', flushInterval: const Duration(minutes: 5)));
    final dio = Dio();
    DioException? failed;
    try {
      await dio.get('http://127.0.0.1:${server.port}/hcp/nearby-hcps', options: Options(headers: {'Authorization': 'Bearer abcdefghijklmnopqrstu'}));
    } on DioException catch (e) {
      failed = e;
    }
    expect(failed?.response?.statusCode, 401);
    expect((failed?.response?.data as Map)['detail'], 'Not authenticated', reason: "the app's own Dio sees the answer unchanged");
    final ok = await dio.get('http://127.0.0.1:${server.port}/ok');
    expect(ok.data, {'doctors': []});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await LoggerAI.flush();
    final net = batches.expand((b) => (b['events'] as List)).where((e) => e['type'] == 'network_request').map((e) => e['payload'] as Map).toList();
    final bad = net.firstWhere((p) => '${p['url']}'.contains('nearby-hcps'));
    expect(bad['status'], 401);
    expect(bad['response_data'], {'detail': 'Not authenticated', 'token': '[REDACTED]'});
    expect((bad['request_headers'] as Map)['authorization'], '[REDACTED]');
    final good = net.firstWhere((p) => '${p['url']}'.endsWith('/ok'));
    expect(good.containsKey('response_data'), isFalse);
    LoggerAI.client!.close();
  });
}
