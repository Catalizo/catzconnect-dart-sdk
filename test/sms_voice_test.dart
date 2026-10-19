// SMS and Voice helpers against the TypeScript SDK's answers.

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_sodium.dart';

List<Map<String, dynamic>> _list(Object? v) =>
    (v! as List<Object?>).map((Object? e) => e! as Map<String, dynamic>).toList();

String _short(String s) => s.length > 24 ? '${s.substring(0, 24)}… (${s.length})' : s;

void main() {
  final Map<String, dynamic> v = loadVectors();
  final Map<String, dynamic> sms = v['sms'] as Map<String, dynamic>;
  final Map<String, dynamic> voice = v['voice'] as Map<String, dynamic>;

  group('analyseSms', () {
    for (final Map<String, dynamic> c in _list(sms['analyse'])) {
      test(_short(c['text'] as String), () {
        expect(analyseSms(c['text'] as String).toJson(), c['result']);
      });
    }
  });

  test('normaliseE164', () {
    for (final Map<String, dynamic> c in _list(sms['e164'])) {
      expect(normaliseE164(c['input'] as String), c['result'], reason: c['input'] as String);
    }
  });

  test('isValidSmsSender', () {
    for (final Map<String, dynamic> c in _list(sms['sender'])) {
      expect(isValidSmsSender(c['input'] as String), c['result'], reason: c['input'] as String);
    }
  });

  test('isValidDltId', () {
    for (final Map<String, dynamic> c in _list(sms['dlt'])) {
      expect(isValidDltId(c['input'] as String), c['result'], reason: c['input'] as String);
    }
  });

  test('validateE164 throws the server sentence', () {
    expect(validateE164(' +91 98765-43210 '), '+919876543210');
    expect(
      () => validateE164(' 98765 '),
      throwsA(isA<CatzValidationException>().having((CatzValidationException e) => e.message, 'message',
          "'98765' is not an E.164 phone number — use + and the country code, e.g. +919876543210")),
    );
  });

  test('validateSmsBody', () {
    expect(validateSmsBody('Hello').segments, 1);
    expect(() => validateSmsBody(' '), throwsA(isA<CatzValidationException>()));
    expect(kSmsMaxSegments, 10);
  });

  test('isValidVoiceLanguage', () {
    for (final Map<String, dynamic> c in _list(voice['language'])) {
      expect(isValidVoiceLanguage(c['input'] as String), c['result'], reason: c['input'] as String);
    }
  });

  test('isValidVoiceName', () {
    for (final Map<String, dynamic> c in _list(voice['name'])) {
      expect(isValidVoiceName(c['input'] as String), c['result'], reason: c['input'] as String);
    }
  });

  test('validateVoiceText', () {
    for (final Map<String, dynamic> c in _list(voice['text'])) {
      final String input = c['input'] as String;
      final String? error = c['error'] as String?;
      if (error == null) {
        expect(validateVoiceText(input), c['result'], reason: _short(input));
      } else {
        expect(
          () => validateVoiceText(input),
          throwsA(isA<CatzValidationException>().having((CatzValidationException e) => e.message, 'message', error)),
          reason: _short(input),
        );
      }
    }
  });

  test('parseVoiceRepeat', () {
    for (final Map<String, dynamic> c in _list(voice['repeat'])) {
      final String input = c['input'] as String;
      final String? error = c['error'] as String?;
      if (error == null) {
        expect(parseVoiceRepeat(input), c['result'], reason: input);
      } else {
        expect(() => parseVoiceRepeat(input), throwsA(isA<CatzValidationException>()), reason: input);
      }
    }
    // Numbers as JavaScript reads them.
    expect(parseVoiceRepeat(2), 2);
    expect(parseVoiceRepeat(2.0), 2);
    expect(() => parseVoiceRepeat(2.5), throwsA(isA<CatzValidationException>()));
    expect(() => parseVoiceRepeat(null), throwsA(isA<CatzValidationException>()));
  });
}
