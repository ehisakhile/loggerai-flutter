## 0.1.1

* Locations are never sent: keys like `lat`, `lng`, `lon`, `latitude`, `longitude`, `user_lat`, `userLng`,
  `coords`, `ll` and `location` in URLs, fields and events are masked, and so are latitude,longitude pairs in
  paths. Network capture is safe to leave on when your API puts the user's position in the URL.

## 0.1.0

* First release: crashes and errors grouped with their stack (Flutter, async and platform errors), screens through a
  navigator observer, network calls (package:http, Dio, HttpClient) with trace headers for your own API, app lifecycle,
  custom events, and "Report a problem": a note, a screenshot and a screen recording the user makes, with text
  fields masked, sent as an issue with the session. Android, iOS, macOS, Windows, Linux; the web without network capture.
