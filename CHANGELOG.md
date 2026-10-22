## 0.1.2

* The report sheet shows the upload: a progress bar with "Uploading recording… 45%", then "Almost done…" while
  the server saves it. `LoggerAI.report` takes `onProgress: (sent, total)` for your own UI.
* A report on a slow connection no longer fails after 60 seconds while it is still uploading: it gives up only
  when nothing has moved for 30 seconds.
* An example app (`example/`): screens, a network call, a caught error, a crash and Report a problem.

## 0.1.1

* Locations are never sent: keys like `lat`, `lng`, `lon`, `latitude`, `longitude`, `user_lat`, `userLng`,
  `coords`, `ll` and `location` in URLs, fields and events are masked, and so are latitude,longitude pairs in
  paths. Network capture is safe to leave on when your API puts the user's position in the URL.

## 0.1.0

* First release: crashes and errors grouped with their stack (Flutter, async and platform errors), screens through a
  navigator observer, network calls (package:http, Dio, HttpClient) with trace headers for your own API, app lifecycle,
  custom events, and "Report a problem": a note, a screenshot and a screen recording the user makes, with text
  fields masked, sent as an issue with the session. Android, iOS, macOS, Windows, Linux; the web without network capture.
