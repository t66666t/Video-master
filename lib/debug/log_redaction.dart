/// Masks login secrets (Bilibili cookies and tokens) before text reaches the
/// in-app debug console or the VM service log.
///
/// Covers `name=value` (cookie headers, query strings) and JSON-style
/// `"name": "value"` forms.
library;

const List<String> _sensitiveNames = <String>[
  'SESSDATA',
  'bili_jct',
  'DedeUserID__ckMd5',
  'DedeUserID',
  'sid',
  'refresh_token',
  'access_token',
  'access_key',
];

final RegExp _assignment = RegExp(
  '\\b(${_sensitiveNames.join('|')})=([^;&\\s"\',]+)',
  caseSensitive: false,
);

final RegExp _jsonField = RegExp(
  '(["\'](?:${_sensitiveNames.join('|')})["\']\\s*:\\s*["\'])([^"\']*)(["\'])',
  caseSensitive: false,
);

String redactSensitiveLogText(String text) {
  if (text.isEmpty) return text;
  var out = text.replaceAllMapped(_assignment, (m) => '${m[1]}=***');
  out = out.replaceAllMapped(_jsonField, (m) => '${m[1]}***${m[3]}');
  return out;
}
