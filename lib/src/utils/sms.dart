// SMS helpers that mirror the server's checks for `channel: SMS`, so a request
// the server would refuse fails before it is encrypted and sent.
// Port of sdk/typescript/src/utils/sms.ts.

import '../core/errors.dart';
import 'validators.dart';

/// Longest body the server accepts, in segments (~1,530 GSM-7 / ~670 UCS-2
/// characters). `SMS_MAX_SEGMENTS` in the TypeScript SDK.
const int kSmsMaxSegments = 10;

/// How the server encodes a message.
enum SmsEncoding {
  gsm7('gsm7'),
  ucs2('ucs2');

  const SmsEncoding(this.wire);
  final String wire;

  @override
  String toString() => wire;
}

/// The result of [analyseSms].
class SmsAnalysis {
  const SmsAnalysis({required this.encoding, required this.units, required this.segments, required this.chars});

  final SmsEncoding encoding;

  /// Septets (GSM-7) or UTF-16 code units (UCS-2).
  final int units;

  /// Billable parts.
  final int segments;

  /// Characters as a person would count them.
  final int chars;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'encoding': encoding.wire, 'units': units, 'segments': segments, 'chars': chars};

  @override
  bool operator ==(Object other) =>
      other is SmsAnalysis &&
      other.encoding == encoding &&
      other.units == units &&
      other.segments == segments &&
      other.chars == chars;

  @override
  int get hashCode => Object.hash(encoding, units, segments, chars);

  @override
  String toString() => 'SmsAnalysis(${toJson()})';
}

final RegExp _e164Formatting = RegExp(r'[ \-.()]');
final RegExp _e164 = RegExp(r'^\+[1-9]\d{7,14}$');
final RegExp _senderId = RegExp(r'^[A-Za-z0-9 ]{2,11}$');
final RegExp _hasLetter = RegExp(r'[A-Za-z]');
final RegExp _dltId = RegExp(r'^\d{6,30}$');

/// Normalises a phone number to E.164 the way the server does: spaces,
/// dashes, dots and brackets are removed; the result must be `+` and 8–15
/// digits, not starting with 0. Returns `null` when it is not E.164.
String? normaliseE164(String raw) {
  final String cleaned = raw.trim().replaceAll(_e164Formatting, '');
  return _e164.hasMatch(cleaned) ? cleaned : null;
}

/// Throws unless [phone] is an E.164 number (after removing formatting), and
/// returns the normalised number.
String validateE164(String phone) {
  final String? n = normaliseE164(phone);
  if (n == null) {
    fail("'${phone.trim()}' is not an E.164 phone number — use + and the country code, e.g. +919876543210");
  }
  return n;
}

/// A sender override: an E.164 number, or a 2–11 character alphanumeric
/// sender ID.
bool isValidSmsSender(String s) {
  if (s.startsWith('+')) {
    return normaliseE164(s) == s;
  }
  return _senderId.hasMatch(s) && _hasLetter.hasMatch(s) && !s.startsWith(' ') && !s.endsWith(' ');
}

/// An India DLT template id: 6–30 digits.
bool isValidDltId(String s) => _dltId.hasMatch(s);

// GSM 03.38 default alphabet (ESC excluded) and extension table (ESC + char).
const String _gsmBasic =
    "@£\$¥èéùìòÇ\nØø\rÅåΔ_ΦΓΛΩΠΨΣΘΞÆæßÉ !\"#¤%&'()*+,-./0123456789:;<=>?¡ABCDEFGHIJKLMNOPQRSTUVWXYZÄÖÑÜ§¿abcdefghijklmnopqrstuvwxyzäöñüà";
const String _gsmExtension = '^{}\\[~]|€\f';

final Set<int> _gsmBasicSet = _gsmBasic.runes.toSet();
final Set<int> _gsmExtensionSet = _gsmExtension.runes.toSet();

int? _gsmCost(int rune) {
  if (_gsmBasicSet.contains(rune)) return 1;
  if (_gsmExtensionSet.contains(rune)) return 2;
  return null;
}

int _countSegments(List<int> costs, int total, int single, int multi) {
  if (total <= single) return 1;
  int parts = 1;
  int used = 0;
  for (final int c in costs) {
    if (used + c > multi) {
      parts += 1;
      used = 0;
    }
    used += c;
  }
  return parts;
}

/// How the server will encode [text] and how many segments it takes: GSM-7
/// when every character is in the GSM alphabet (extension characters cost
/// two), otherwise UCS-2. 160/153 septets or 70/67 code units per part.
SmsAnalysis analyseSms(String text) {
  final List<int> runes = text.runes.toList();
  final List<int?> gsm = runes.map(_gsmCost).toList();
  if (gsm.every((int? c) => c != null)) {
    final List<int> costs = gsm.map((int? c) => c!).toList();
    final int units = costs.fold(0, (int a, int b) => a + b);
    return SmsAnalysis(
      encoding: SmsEncoding.gsm7,
      units: units,
      segments: _countSegments(costs, units, 160, 153),
      chars: runes.length,
    );
  }
  // UTF-16 code units: 2 for astral characters.
  final List<int> costs = runes.map((int r) => r > 0xFFFF ? 2 : 1).toList();
  final int units = costs.fold(0, (int a, int b) => a + b);
  return SmsAnalysis(
    encoding: SmsEncoding.ucs2,
    units: units,
    segments: _countSegments(costs, units, 70, 67),
    chars: runes.length,
  );
}

/// Throws the server's error when [body] would be refused (empty, control
/// characters, too long); returns its analysis otherwise.
SmsAnalysis validateSmsBody(String body) {
  if (body.trim().isEmpty) {
    fail('The message is empty');
  }
  if (hasControlCharsExceptWhitespace(body)) {
    fail('The message contains control characters');
  }
  final SmsAnalysis a = analyseSms(body);
  if (a.segments > kSmsMaxSegments) {
    fail('The message is ${a.segments} segments long; the limit is $kSmsMaxSegments '
        '(${a.encoding == SmsEncoding.gsm7 ? 1530 : 670} characters in ${a.encoding.wire.toUpperCase()})');
  }
  return a;
}
