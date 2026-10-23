/// LoggerAI for Flutter: crashes and errors grouped with their stack, the
/// screens people visit, the network calls the app makes, and a report sheet,
/// all in a session linked to your server's requests.
library;

export 'src/capture.dart' show LoggerAIMask, ScreenRecorder;
export 'src/client.dart' show LoggerAIOptions, Client, LoggerAIReportException, MyReport, NetworkDetails;
export 'src/loggerai.dart';
export 'src/redact.dart' show redact, redactString, redactUrl, isSensitive, isPersonal;
