// Masks secrets before anything leaves the app: by key name (fields, headers,
// query parameters) and by shape (bearer tokens and JWTs anywhere in a string).
// The same rules as LoggerAI's server, browser script and other SDKs.

const mask = '[REDACTED]';

const _words = {
  'password', 'passwd', 'pwd', 'pass', 'passphrase', 'secret', 'token', 'otp', 'pin', 'cvv', 'cvc', //
  'ssn', 'cookie', 'authorization', 'auth', 'signature', 'sig', 'credential', 'credentials', 'bvn', 'nin',
};
const _joined = [
  'apikey', 'accesskey', 'privatekey', 'secretkey', 'cardnumber', 'clientsecret', 'sessionid', //
  'authtoken', 'accesstoken', 'refreshtoken', 'idtoken', 'csrftoken', 'xsrf', 'setcookie',
];
const _urlExtra = {'key', 'code', 'access_token', 'id_token'};

final _split = RegExp(r'[^A-Za-z0-9]+|(?<=[a-z0-9])(?=[A-Z])');
final _jwt = RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}');
final _bearer = RegExp(r'\b(bearer|basic|token)\s+[A-Za-z0-9\-._~+/]{12,}=*', caseSensitive: false);

bool isSensitive(String key) {
  if (key.isEmpty) return false;
  final words = key.split(_split).where((w) => w.isNotEmpty).map((w) => w.toLowerCase()).toList();
  if (words.any(_words.contains)) return true;
  final joined = words.join();
  return _joined.any(joined.contains);
}

String redactString(String s) =>
    s.replaceAll(_jwt, '[REDACTED_JWT]').replaceAllMapped(_bearer, (m) => '${m.group(1)} $mask');

String redactUrl(String url) {
  final u = Uri.tryParse(url);
  if (u == null || (!u.hasQuery && u.userInfo.isEmpty)) return redactString(url);
  var out = url;
  if (u.userInfo.isNotEmpty) out = out.replaceFirst('${u.userInfo}@', '$mask@');
  if (u.hasQuery) {
    final q = u.query
        .split('&')
        .map((pair) {
          final eq = pair.indexOf('=');
          if (eq < 0) return pair;
          final k = Uri.decodeQueryComponent(pair.substring(0, eq));
          final v = pair.substring(eq + 1);
          final secret = v.isNotEmpty && (isSensitive(k) || _urlExtra.contains(k.toLowerCase()));
          return secret ? '${pair.substring(0, eq)}=$mask' : pair;
        })
        .join('&');
    out = out.replaceFirst('?${u.query}', '?$q');
  }
  return redactString(out);
}

/// A copy of [value] (maps, lists, strings) with secrets masked.
Object? redact(Object? value, [int depth = 0]) {
  if (depth > 40) return value;
  if (value is Map) {
    return value.map((k, v) {
      final key = k.toString();
      final empty = v == null || v == '' || (v is Map && v.isEmpty) || (v is List && v.isEmpty);
      if (isSensitive(key) && !empty) return MapEntry(key, mask);
      if (v is String && const {'url', 'href', 'referrer', 'referer', 'location'}.contains(key.toLowerCase())) {
        return MapEntry(key, redactUrl(v));
      }
      return MapEntry(key, redact(v, depth + 1));
    });
  }
  if (value is List) return value.map((v) => redact(v, depth + 1)).toList();
  if (value is String) return value.startsWith(RegExp('https?://')) ? redactUrl(value) : redactString(value);
  return value;
}
