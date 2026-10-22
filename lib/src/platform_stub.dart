// The web (no dart:io): no HttpClient to wrap.
import 'package:flutter/foundation.dart';

String osName() => kIsWeb ? 'web' : defaultTargetPlatform.name;

void captureNetwork(Object client) {}
