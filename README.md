# LoggerAI for Flutter

Crash reporting and session recording for Flutter apps, in the same place as
your server's monitoring, with AI that explains what went wrong.

- **Crashes and errors**, grouped by cause with their stack: Flutter's own
  errors (build, layout, gestures), uncaught async errors, platform errors, and
  ones you report yourself.
- **Sessions**: the screens people visit, the network calls the app makes
  (package:http, Dio and HttpClient), the app going to the background and back,
  and your own events, in order, so you see what led up to a problem.
- **Linked to your server**: calls to your own API carry `traceparent` and
  `x-loggerai-session`, so LoggerAI shows the exact server request behind a
  failed tap (with LoggerAI's Laravel, Python, Node.js or Java SDK on the server).
- **A report sheet**: people describe a problem in the app, and the team gets
  it with the whole session attached.

Secrets (passwords, tokens, cookies, API keys, JWTs) are masked before
anything leaves the app, and request and response bodies are never sent.
Android, iOS, macOS, Windows and Linux; on the web everything but network
capture.

## Install

```bash
flutter pub add loggerai_flutter
```

Use your project's **public key** (`pk_live_...`, from LoggerAI → your
project → **Connect**). It's safe to ship in the app: it can only send
sessions, events and errors. Never put the secret key in an app.

```dart
import 'package:loggerai_flutter/loggerai_flutter.dart';

void main() => LoggerAI.run(
      const LoggerAIOptions(
        publicKey: 'pk_live_...',
        release: '1.4.2',                 // your app version: "since release X"
        traceHosts: ['api.shop.com'],     // your own API, to link calls to server requests
      ),
      () => runApp(const ShopApp()),
    );
```

Name screens as people move between them:

```dart
MaterialApp(
  navigatorObservers: [LoggerAI.navigatorObserver],
  ...
)

// GoRouter
GoRouter(observers: [LoggerAI.navigatorObserver], ...)
```

Named routes (`/cart`) are used as screen names. For tabs or screens without a
route, call `LoggerAI.setScreen('Cart')`.

## More

```dart
// An error you caught but still want to see
try {
  await checkout();
} catch (e, s) {
  LoggerAI.captureException(e, s, {'basket': basket.id});
}

// Count the session against a user: an opaque id, never an email or a name
LoggerAI.setUser(user.id);

// Something worth seeing in the timeline
LoggerAI.event('coupon_applied', {'coupon': 'SAVE10'});

// A "Report a problem" button
TextButton(onPressed: () => LoggerAI.showReportSheet(context), child: const Text('Report a problem'));
```

If you set up error handling yourself, call `LoggerAI.init(options)` after
`WidgetsFlutterBinding.ensureInitialized()` instead of `LoggerAI.run`; it
chains onto `FlutterError.onError` and `PlatformDispatcher.onError` without
replacing what's there.

## Options

| Option | Default |
| --- | --- |
| `publicKey` | required |
| `release` | none |
| `environment` | `production` in release builds, `development` otherwise |
| `service` | `app` |
| `appPackages` | everything but Flutter, Dart and well-known libraries counts as your code |
| `traceHosts` | none |
| `captureNetwork` | `true` |
| `flushInterval` | 10 seconds (and whenever the app goes to the background or crashes) |
| `sessionTimeout` | 30 minutes in the background starts a new session |
| `enabled` | `true` (pass `kReleaseMode` to send from release builds only) |

## How it behaves

- Data goes out every 10 seconds, when the app goes to the background, and
  right after a crash. Nothing blocks the UI or throws into the app.
- When LoggerAI can't be reached, data waits in memory (up to 1,000 events) for
  the next try; nothing is written to the device.

## Development

```bash
flutter test
```

A tag like `v0.1.0` runs the tests and publishes to pub.dev.
