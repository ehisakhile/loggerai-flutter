## 0.1.3

* The recording bar's clock runs (it only moved when something else redrew the screen).
* No screenshot is taken when the sheet opens. **Take a screenshot** in the sheet and a camera on the recording
  bar add up to five, each one removable.
* After sending: "The team has your report", what they received, the report number and **See my reports**.
* Failed network calls (400 and up, or no answer) keep their headers and bodies, masked and cut to 4 KB, so the
  timeline shows why they failed. `networkDetails` and `maxBodyBytes` change it.
* **My reports** (`LoggerAI.showMyReportsSheet`, `LoggerAI.myReports()`): the user's reports, open and resolved.
  `setUser(id, hash: ...)` with a signature from your server shows them on any device; otherwise the ones sent
  from this device.

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
