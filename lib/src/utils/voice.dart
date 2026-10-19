// Phone calls (text-to-speech) through send() with Channel.voice. These mirror
// the server's checks so a refused request fails before it is encrypted and
// sent. Port of sdk/typescript/src/utils/voice.ts.

import '../core/errors.dart';
import '../types.dart';
import 'sms.dart';
import 'validators.dart';

/// Longest Custom text a phone call speaks. `VOICE_MAX_CHARS` in TypeScript.
const int kVoiceMaxChars = 1000;

/// Most times the message is repeated. `VOICE_MAX_REPEAT` in TypeScript.
const int kVoiceMaxRepeat = 3;

const List<MessageType> _voiceTypes = <MessageType>[
  MessageType.verification,
  MessageType.transactional,
  MessageType.notification,
  MessageType.promotional,
];

final RegExp _language = RegExp(r'^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8}){0,2}$');
final RegExp _voiceName = RegExp(r'^[A-Za-z0-9._:\- ]{1,64}$');
final RegExp _digits = RegExp(r'^\d+$');
final RegExp _otp = RegExp(r'^[A-Za-z0-9]{1,15}$');

/// A BCP-47 style language tag such as `en-US`, `hi-IN`, `es-419` or `fr`.
bool isValidVoiceLanguage(String s) => _language.hasMatch(s);

/// `female`, `male`, or a provider voice name such as `Polly.Joanna` or
/// `en-US-Wavenet-F`.
bool isValidVoiceName(String s) => _voiceName.hasMatch(s) && s.trim() == s;

/// Throws the server's error when a Custom text would be refused (empty,
/// control characters, over 1,000 characters); returns the trimmed text.
String validateVoiceText(String text) {
  final String t = text.trim();
  if (t.isEmpty) {
    fail('The text to speak is empty');
  }
  if (hasControlCharsExceptWhitespace(t)) {
    fail('The text to speak contains control characters');
  }
  final int n = codePointLength(t);
  if (n > kVoiceMaxChars) {
    fail('The text to speak is $n characters; the limit is $kVoiceMaxChars');
  }
  return t;
}

/// `repeat` as the server reads it from `data`: a whole number 1–3, given as
/// a string (`"2"`) or a number.
int parseVoiceRepeat(Object? v) {
  String s;
  if (v is int) {
    s = v.toString();
  } else if (v is double) {
    // JavaScript's String(2.0) is "2".
    s = (v.isFinite && v == v.truncateToDouble()) ? v.toInt().toString() : v.toString();
  } else if (v is String) {
    s = v.trim();
  } else {
    s = '';
  }
  if (!_digits.hasMatch(s)) {
    fail("'data.repeat' must be a whole number from 1 to 3");
  }
  final int? n = int.tryParse(s);
  if (n == null || n < 1 || n > kVoiceMaxRepeat) {
    fail("'data.repeat' must be a whole number from 1 to 3");
  }
  return n;
}

/// The server's checks for [Channel.voice]: an E.164 `to`; template `Otp`
/// with `otp` (up to 15 letters or digits, read out one by one), `Custom`
/// with `body` (≤ 1,000 characters), or the name of a Voice template from
/// the panel filled from `data`. `data.language`, `data.voice` and
/// `data.repeat` (1–3) are optional. `identity` is ignored.
void verifyVoice(SendInput input) {
  final SendPayload payload = input.payload;

  final String? to = payload.to;
  if (to == null || to.trim().isEmpty) {
    fail("Missing 'to' in payload — the number to call in E.164, e.g. +14155550100");
  }
  validateE164(to);

  if (!_voiceTypes.contains(input.type)) {
    fail('Voice supports type Verification, Transactional, Notification or Promotional — not ${input.type.wire}');
  }

  final String? provider = payload.provider;
  if (provider != null && provider.trim().isEmpty) {
    fail("'provider' must be a phone provider's id or label");
  }

  final Map<String, String>? data = payload.data;
  if (data != null) {
    for (final MapEntry<String, String> e in data.entries) {
      if (e.key == 'repeat') {
        parseVoiceRepeat(e.value);
        continue;
      }
      if (e.key == 'language' && !isValidVoiceLanguage(e.value)) {
        fail("'data.language' must be a language tag such as en-US");
      }
      if (e.key == 'voice' && !isValidVoiceName(e.value)) {
        fail("'data.voice' must be female, male or a provider voice name");
      }
    }
  }

  final String name = input.template.trim();
  if (name.isEmpty) {
    fail("Missing 'template' — Otp, Custom, or the name of a Voice template");
  }

  if (name.toLowerCase() == 'otp') {
    final String? otp = payload.otp;
    if (otp == null || otp.trim().isEmpty) {
      fail("Missing 'otp' in payload");
    }
    if (!_otp.hasMatch(otp.trim())) {
      fail("'otp' must be up to 15 letters or digits");
    }
    return;
  }

  if (name.toLowerCase() == 'custom') {
    final String? body = payload.body;
    if (body == null || body.trim().isEmpty) {
      fail("Missing 'body' in payload — the text to speak");
    }
    validateVoiceText(body);
  }
  // A panel Voice template: the server renders it from data.
}

/// The JSON body (before encryption) for a Voice send: only the fields the
/// server reads.
Map<String, dynamic> buildVoicePayload(SendInput input) {
  final SendPayload p = input.payload;
  final String name = input.template.trim();
  final String lower = name.toLowerCase();
  final Map<String, dynamic> out = <String, dynamic>{
    'message_type': input.type.wire,
    'channel': 'Voice',
    'template': lower == 'otp' ? 'Otp' : (lower == 'custom' ? 'Custom' : name),
    'identity': input.identity, // required by the server, ignored for Voice
    'to': validateE164(p.to ?? ''),
  };
  final String? otp = p.otp;
  if (otp != null && otp.trim().isNotEmpty) out['otp'] = otp.trim();
  final String? body = p.body;
  if (body != null && body.trim().isNotEmpty) out['body'] = body.trim();
  final String? provider = p.provider;
  if (provider != null && provider.trim().isNotEmpty) out['provider'] = provider.trim();
  final Map<String, String>? data = p.data;
  if (data != null && data.isNotEmpty) {
    final Map<String, String> d = <String, String>{};
    for (final MapEntry<String, String> e in data.entries) {
      // The server's data is a map of strings; repeat travels as "1".."3".
      d[e.key] = e.key == 'repeat' ? parseVoiceRepeat(e.value).toString() : e.value;
    }
    out['data'] = d;
  }
  return out;
}
