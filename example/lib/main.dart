// LoggerAI for Flutter: a small app that shows crashes, screens, network calls
// and "Report a problem".
//
//   flutter run --dart-define=LOGGERAI_KEY=pk_live_...
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:loggerai_flutter/loggerai_flutter.dart';

// The project's public key: safe to ship in an app. Never use the secret key here.
const publicKey = String.fromEnvironment('LOGGERAI_KEY');

void main() => LoggerAI.run(
      const LoggerAIOptions(
        publicKey: publicKey,
        release: '1.0.0', // your app's version, so issues say "since release 1.0.0"
        service: 'example-app',
        traceHosts: ['api.example.com'], // your own API: its calls link to server requests
        enabled: publicKey != '',
      ),
      () => runApp(const ShopApp()),
    );

class ShopApp extends StatelessWidget {
  const ShopApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoggerAI example',
      theme: ThemeData(colorSchemeSeed: const Color(0xFF17A34A), useMaterial3: true),
      // Names each screen from its route as people move around.
      navigatorObservers: [LoggerAI.navigatorObserver],
      routes: {
        '/': (_) => const HomePage(),
        '/basket': (_) => const BasketPage(),
      },
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  String _status = '';

  @override
  void initState() {
    super.initState();
    // Count the session against a user: an opaque id, never an email or a name.
    LoggerAI.setUser('user-1042');
  }

  Future<void> _loadProducts() async {
    // Recorded as a network call (method, URL with secrets masked, status, time).
    final r = await http.get(Uri.parse('https://httpbin.org/status/200'));
    LoggerAI.event('products_loaded', {'status': r.statusCode});
    setState(() => _status = 'Loaded (${r.statusCode})');
  }

  void _caughtError() {
    try {
      throw StateError('Coupon service returned no discount');
    } catch (e, s) {
      // An error you handled but still want to see, with context.
      LoggerAI.captureException(e, s, {'coupon': 'SAVE10'});
      setState(() => _status = 'Reported a caught error');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shop')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          if (publicKey == '')
            const Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text('Run with --dart-define=LOGGERAI_KEY=pk_live_... to send to LoggerAI.'),
            ),
          FilledButton(onPressed: _loadProducts, child: const Text('Load products')),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: () => Navigator.of(context).pushNamed('/basket'), child: const Text('Open basket')),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: _caughtError, child: const Text('Caught error')),
          const SizedBox(height: 12),
          // Uncaught: LoggerAI reports it as a crash, with the screens and calls before it.
          OutlinedButton(onPressed: () => throw StateError('Pay button crashed'), child: const Text('Crash')),
          const SizedBox(height: 24),
          TextButton.icon(
            onPressed: () => LoggerAI.showReportSheet(context, askContact: true),
            icon: const Icon(Icons.bug_report_outlined),
            label: const Text('Report a problem'),
          ),
          TextButton.icon(
            onPressed: () => LoggerAI.showMyReportsSheet(context),
            icon: const Icon(Icons.inbox_outlined),
            label: const Text('My reports'),
          ),
          if (_status.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 16), child: Text(_status)),
        ],
      ),
    );
  }
}

class BasketPage extends StatelessWidget {
  const BasketPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Basket')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const ListTile(title: Text('Running shoes'), trailing: Text('£64.00')),
          // Painted over in screenshots and recordings, like every text field.
          const LoggerAIMask(child: ListTile(title: Text('Card ending 4242'), subtitle: Text('Hidden in reports'))),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => LoggerAI.showReportSheet(context),
            child: const Text('Report a problem'),
          ),
        ],
      ),
    );
  }
}
