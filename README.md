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
- **Report a problem**: people describe what went wrong, keep a screenshot of
  the screen they were on and can record the screen while they show it. The
  team gets an issue with all of it and the session's steps, and a message in
  Slack.

Secrets (passwords, tokens, cookies, API keys, JWTs) and locations
(`lat`, `lng`, `user_lat`, `latitude`... and coordinate pairs in paths) are
masked before anything leaves the app, and request and response bodies are
never sent. So network capture is safe to leave on even when your API puts
the user's position in the URL.
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

```

## Report a problem

```dart
TextButton(
  onPressed: () => LoggerAI.showReportSheet(context, askContact: true),
  child: const Text('Report a problem'),
);
```

The sheet takes a screenshot of the screen the user was on before it opens.
**Record the problem** hides the sheet and records the screen (a few frames a
second, up to a minute) while a small pill shows the time and **Stop**; then
the sheet comes back with the recording, and **Send** creates the issue, with a
progress bar while it uploads. Your team sees it on the Issues page with the
recording, the screenshot, what the user did before it and any errors just
before, and your Slack alert channels get a message.

Text fields are painted over in screenshots and recordings, and so is anything
you wrap in `LoggerAIMask`:

```dart
LoggerAIMask(child: Text(account.iban))
```

No plugin or permission is needed: Flutter draws the screen, so the SDK takes
its picture of what Flutter drew (system dialogs, the keyboard and platform
views such as maps or web views aren't in it).

Your own UI instead of the sheet:

```dart
final shot = await LoggerAI.screenshot();
final recorder = ScreenRecorder()..start();
// ...later
final recording = await recorder.stop();
try {
  await LoggerAI.report(note, screenshot: shot, recording: recording,
      onProgress: (sent, total) => setState(() => progress = sent / total));
} on LoggerAIReportException catch (e) {
  showError(e.message); // in words for the user
}
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
| `maskTextFields` | `true`: every text field is painted over in screenshots and recordings |

## How it behaves

- Data goes out every 10 seconds, when the app goes to the background, and
  right after a crash. Nothing blocks the UI or throws into the app.
- When LoggerAI can't be reached, data waits in memory (up to 1,000 events) for
  the next try; nothing is written to the device.
- Nothing about the screen is captured until the user opens the report sheet,
  and recording only runs between their Record and Stop.

## Development

```bash
flutter test
```

A tag like `v0.1.0` runs the tests and publishes to pub.dev.
