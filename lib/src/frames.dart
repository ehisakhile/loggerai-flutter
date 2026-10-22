// Stack frames for an error, innermost first, with the app's own code marked
// (in_app) so LoggerAI groups errors by where they happened in your code.

// #0      CartScreen._checkout (package:shop/screens/cart.dart:42:7)
// #1      _rootRunUnary (dart:async/zone.dart:1415:13)
final _vm = RegExp(r'^#\d+\s+(.+?) \((.+?)(?::(\d+))?(?::(\d+))?\)$');
// package:shop/screens/cart.dart 42:7  CartScreen._checkout   (web, terse)
final _terse = RegExp(r'^(\S+) (\d+)(?::\d+)?\s+(.+)$');

const _libraries = [
  'dart:', 'package:flutter/', 'package:flutter_test/', 'package:loggerai_flutter/', 'package:http/', 'package:dio/', //
  'package:provider/', 'package:riverpod/', 'package:flutter_riverpod/', 'package:bloc/', 'package:flutter_bloc/',
  'package:get/', 'package:go_router/', 'package:stack_trace/', 'org-dartlang-sdk:',
];

bool inApp(String file, List<String> appPackages) {
  if (appPackages.isNotEmpty) return appPackages.any((p) => file.startsWith('package:$p/'));
  if (file == '<asynchronous suspension>' || file.isEmpty) return false;
  return !_libraries.any(file.startsWith);
}

List<Map<String, Object?>> frames(StackTrace? stack, List<String> appPackages, {int limit = 50}) {
  if (stack == null) return const [];
  final out = <Map<String, Object?>>[];
  for (final raw in stack.toString().split('\n')) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('<asynchronous')) continue;
    String fn, file;
    int lineNo = 0;
    final m = _vm.firstMatch(line);
    if (m != null) {
      fn = m.group(1)!;
      file = m.group(2)!;
      lineNo = int.tryParse(m.group(3) ?? '') ?? 0;
    } else {
      final t = _terse.firstMatch(line);
      if (t == null) continue;
      file = t.group(1)!;
      lineNo = int.tryParse(t.group(2)!) ?? 0;
      fn = t.group(3)!;
    }
    String? cls;
    var function = fn.replaceAll('<anonymous closure>', '<closure>');
    final dot = function.indexOf('.');
    if (dot > 0) {
      cls = function.substring(0, dot);
      function = function.substring(dot + 1);
    }
    out.add({'file': file, 'line': lineNo, 'function': function, 'class': cls, 'in_app': inApp(file, appPackages)});
    if (out.length >= limit) break;
  }
  return out;
}
