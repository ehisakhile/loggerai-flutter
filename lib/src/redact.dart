// Masks secrets and personal details before anything leaves the app: by key name
// (fields, headers, query parameters) and by shape (bearer tokens, JWTs, emails and
// phone numbers anywhere in a string).
// The same rules as LoggerAI's server, browser script and other SDKs.

const mask = '[REDACTED]';

const _words = {
  'password', 'passwd', 'pwd', 'pass', 'passphrase', 'secret', 'token', 'otp', 'pin', 'cvv', 'cvc', //
  'ssn', 'cookie', 'authorization', 'auth', 'signature', 'sig', 'credential', 'credentials', 'bvn', 'nin',
  // where someone is: user_lat, userLng, pickup_latitude... (analytics never keep locations)
  'lat', 'lng', 'lon', 'latitude', 'longitude', 'coords', 'coordinates', 'geolocation', 'gps',
};
const _joined = [
  'apikey', 'accesskey', 'privatekey', 'secretkey', 'cardnumber', 'clientsecret', 'sessionid', //
  'authtoken', 'accesstoken', 'refreshtoken', 'idtoken', 'csrftoken', 'xsrf', 'setcookie',
  'latlng', 'latlon', 'lnglat', 'lonlat', 'geopoint',
];
// Who someone is and where they live: masked when the value is text or a number (so
// flags like send_email: true stay readable).
const _personal = {
  'phone', 'phones', 'telephone', 'tel', 'mobile', 'msisdn', 'whatsapp', 'email', 'emails', //
  'address', 'addresses', 'street', 'postcode', 'postcodes', 'zip', 'dob', 'birthday', 'birthdate', 'surname', 'iban',
};
const _personalJoined = [
  'phonenumber', 'emailaddress', 'firstname', 'lastname', 'fullname', 'middlename', 'givenname', 'familyname', //
  'displayname', 'contactname', 'dateofbirth', 'postalcode', 'postcode', 'zipcode', 'accountnumber',
];
const _urlExtra = {'key', 'code', 'access_token', 'id_token', 'll', 'location'}; // ?ll=6.52,3.37 (maps)

final _split = RegExp(r'[^A-Za-z0-9]+|(?<=[a-z0-9])(?=[A-Z])');
final _jwt = RegExp(r'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}');
final _bearer = RegExp(r'\b(bearer|basic|token)\s+[A-Za-z0-9\-._~+/]{12,}=*', caseSensitive: false);

final _email = RegExp(r'[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}');
// +234 803 123 4567, +44 20 7946 0958, and Nigerian mobiles written locally (0803 123 4567)
final _phone = RegExp(r'(?<![\w+])\+\d{1,3}[\s-]?\d{2,4}[\s-]?\d{3,4}[\s-]?\d{3,4}(?!\d)|(?<![\d.])0[7-9][01]\d[\s-]?\d{3}[\s-]?\d{4}(?![\d.])');

/// A latitude,longitude pair anywhere, e.g. in a path: /nearby/6.524379,3.379206
final _coords = RegExp(r'(?<![\d.])-?\d{1,3}\.\d{4,}\s*(?:,|%2C)\s*-?\d{1,3}\.\d{4,}(?![\d.])', caseSensitive: false);

bool isSensitive(String key) {
  if (key.isEmpty) return false;
  final words = key.split(_split).where((w) => w.isNotEmpty).map((w) => w.toLowerCase()).toList();
  if (words.any(_words.contains)) return true;
  final joined = words.join();
  return _joined.any(joined.contains);
}

/// A name for a person's details: phone, email, address, postcode, names, date of birth.
bool isPersonal(String key) {
  if (key.isEmpty) return false;
  final words = key.split(_split).where((w) => w.isNotEmpty).map((w) => w.toLowerCase()).toList();
  if (words.any(_personal.contains)) return true;
  final joined = words.join();
  return _personalJoined.any(joined.contains);
}

/// [key] as [LoggerAIOptions.maskKeys] compares it: lower case, letters and digits only.
String normalizeKey(String key) => key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

String redactString(String s) => s
    .replaceAll(_jwt, '[REDACTED_JWT]')
    .replaceAll(_email, '[REDACTED_EMAIL]')
    .replaceAll(_coords, '[REDACTED_LOCATION]')
    .replaceAll(_phone, '[REDACTED_PHONE]')
    .replaceAllMapped(_bearer, (m) => '${m.group(1)} $mask');

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
          final secret = v.isNotEmpty && (isSensitive(k) || isPersonal(k) || _urlExtra.contains(k.toLowerCase()));
          return secret ? '${pair.substring(0, eq)}=$mask' : pair;
        })
        .join('&');
    out = out.replaceFirst('?${u.query}', '?$q');
  }
  return redactString(out);
}

/// A copy of [value] (maps, lists, strings) with secrets and personal details masked.
/// [extraKeys] are more field names to mask, as [normalizeKey] gives them.
Object? redact(Object? value, [int depth = 0, Set<String> extraKeys = const {}]) {
  if (depth > 40) return value;
  if (value is Map) {
    return value.map((k, v) {
      final key = k.toString();
      final empty = v == null || v == '' || (v is Map && v.isEmpty) || (v is List && v.isEmpty);
      if (!empty && (isSensitive(key) || extraKeys.contains(normalizeKey(key)))) return MapEntry(key, mask);
      if (!empty && (v is String || v is num || v is List) && isPersonal(key)) return MapEntry(key, mask);
      if (v is String && const {'url', 'href', 'referrer', 'referer', 'location'}.contains(key.toLowerCase())) {
        return MapEntry(key, redactUrl(v));
      }
      return MapEntry(key, redact(v, depth + 1, extraKeys));
    });
  }
  if (value is List) return value.map((v) => redact(v, depth + 1, extraKeys)).toList();
  if (value is String) return value.startsWith(RegExp('https?://')) ? redactUrl(value) : redactString(value);
  return value;
}
