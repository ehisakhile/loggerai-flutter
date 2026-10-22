# LoggerAI for Flutter: example

A two-screen shop that shows what LoggerAI captures:

- **Screens**, named from the routes (`/` and `/basket`) by `LoggerAI.navigatorObserver`.
- **Network calls**: *Load products* makes a real request with `package:http`.
- **Errors**: *Caught error* reports one you handled with `LoggerAI.captureException`;
  *Crash* throws one you didn't, which LoggerAI reports as a crash.
- **Report a problem**: opens the report sheet with a screenshot, and lets you record the
  screen while you show what goes wrong. A progress bar shows while it uploads.

Run it with your project's public key (LoggerAI → your project → **Connect**):

```bash
cd example
flutter run --dart-define=LOGGERAI_KEY=pk_live_...
```

Without a key the app still runs, and LoggerAI stays switched off.
