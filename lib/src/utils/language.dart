// The optional top-level `language` of send(): the language of the built-in
// (default) Otp/Verification templates. Port of
// sdk/typescript/src/utils/language.ts; the error message is the same.

import '../core/errors.dart';

/// The languages the built-in Otp/Verification templates come in.
/// `SUPPORTED_LANGUAGES` in TypeScript.
const List<String> kSupportedLanguages = <String>['en', 'de', 'ja', 'ar', 'hi'];

final RegExp _tag = RegExp(r'^[A-Za-z0-9]+(?:[-_][A-Za-z0-9]+)*$');

/// Reduces [language] to its BCP-47 primary subtag: `'de'`, `'DE'`,
/// `'de-DE'` and `'de_DE'` all become `'de'`. Throws a
/// [CatzValidationException] when it is not one of en, de, ja, ar, hi.
String normaliseLanguage(String language) {
  final String tag = language.trim();
  final String primary = tag.split(RegExp(r'[-_]')).first.toLowerCase();
  if (!_tag.hasMatch(tag) || !kSupportedLanguages.contains(primary)) {
    fail('Unsupported \'language\' "$language": use one of en, de, ja, ar, hi (or a BCP-47 tag such as de-DE)');
  }
  return primary;
}

/// `true` when [normaliseLanguage] accepts [language].
bool isValidLanguage(String language) {
  try {
    normaliseLanguage(language);
    return true;
  } on CatzValidationException {
    return false;
  }
}
