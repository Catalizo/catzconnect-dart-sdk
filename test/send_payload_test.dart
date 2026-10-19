// send() validation and payload building, checked against the TypeScript
// SDK's output (test/fixtures/vectors.json). Pure Dart: no libsodium needed.

import 'dart:convert';

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_sodium.dart';

void main() {
  final Map<String, dynamic> v = loadVectors();

  group('buildSendPayload matches the TypeScript SDK byte for byte', () {
    for (final Object? raw in v['sends'] as List<Object?>) {
      final Map<String, dynamic> s = raw! as Map<String, dynamic>;
      test(s['name'] as String, () {
        final SendInput input = SendInput.fromJson(s['input'] as Map<String, dynamic>);
        expect(() => verifyPayload(input), returnsNormally);
        expect(jsonEncode(buildSendPayload(input)), s['payload_json']);
      });
    }
  });

  group('validation errors match the TypeScript SDK word for word', () {
    final List<Object?> cases = v['validation'] as List<Object?>;
    for (int i = 0; i < cases.length; i++) {
      final Map<String, dynamic> c = cases[i]! as Map<String, dynamic>;
      final String? expected = c['error'] as String?;
      test('#$i ${expected ?? 'accepted'}', () {
        final SendInput input = SendInput.fromJson(c['input'] as Map<String, dynamic>);
        if (expected == null) {
          expect(() => verifyPayload(input), returnsNormally);
        } else {
          expect(
            () => verifyPayload(input),
            throwsA(isA<CatzValidationException>().having((CatzValidationException e) => e.message, 'message', expected)),
          );
        }
      });
    }
  });

  group('language', () {
    test('normaliseLanguage reduces BCP-47 tags to the primary subtag', () {
      expect(kSupportedLanguages, <String>['en', 'de', 'ja', 'ar', 'hi']);
      const Map<String, String> ok = <String, String>{
        'en': 'en', 'DE': 'de', 'de-DE': 'de', 'ja_JP': 'ja', ' ar-EG ': 'ar', 'hi-Latn-IN': 'hi'};
      for (final MapEntry<String, String> e in ok.entries) {
        expect(normaliseLanguage(e.key), e.value, reason: e.key);
      }
      for (final String bad in <String>['fr', 'fr-FR', '', '-', 'de--DE', 'english', 'd e']) {
        expect(isValidLanguage(bad), isFalse, reason: bad);
        expect(() => normaliseLanguage(bad), throwsA(isA<CatzValidationException>()), reason: bad);
      }
    });

    test('left out of the payload when null', () {
      const SendInput i = SendInput(
        channel: Channel.email,
        type: MessageType.verification,
        template: Template.otp,
        identity: 'a@b.co',
        payload: SendPayload(to: 'u@x.co', otp: '123456'),
      );
      expect(buildSendPayload(i).containsKey('language'), isFalse);
      expect(buildSendPayload(i.copyWith(language: 'hi-IN'))['language'], 'hi');
    });

    test('an unsupported defaultLanguage is refused when the client is made', () {
      expect(() => CatzConnect(defaultLanguage: 'xx'), throwsA(isA<CatzValidationException>()));
      expect(CatzConnect(defaultLanguage: 'AR').defaultLanguage, 'ar');
      expect(CatzConnect().defaultLanguage, isNull);
    });
  });

  group('SendInput', () {
    test('fromJson reads the other SDKs\' map, case-insensitively', () {
      final SendInput i = SendInput.fromJson(<String, dynamic>{
        'channel': 'whatsapp',
        'type': 'verification',
        'template': 'Otp',
        'identity': '919578456444',
        'payload': <String, dynamic>{'to': '+91 98765 43210', 'otp': '123456', 'device_key': 'k', 'data': <String, dynamic>{'n': 1}},
      });
      expect(i.channel, Channel.whatsApp);
      expect(i.type, MessageType.verification);
      expect(i.payload.deviceKey, 'k');
      expect(i.payload.data, <String, String>{'n': '1'});
    });

    test('Channel.parse accepts "voice"', () {
      expect(Channel.parse('voice'), Channel.voice);
      expect(Channel.parse(' SMS '), Channel.sms);
      expect(() => Channel.parse('fax'), throwsArgumentError);
    });

    test('payload toJson leaves out null fields and uses the API names', () {
      const SendPayload p = SendPayload(to: 't', deviceKey: 'dk', externalUserId: null, dltTemplateId: '123456');
      expect(p.toJson(), <String, dynamic>{'to': 't', 'device_key': 'dk', 'dlt_template_id': '123456'});
    });
  });

  group('SendResponse', () {
    test('sms and voice data', () {
      final SendResponse r = SendResponse.fromJson(<String, dynamic>{
        'success': true,
        'message': 'Queued',
        'data': <String, dynamic>{'message_id': 'm1', 'segments': 2, 'encoding': 'ucs2'},
      });
      expect(r.success, isTrue);
      expect(r.sms!.segments, 2);
      expect(r.sms!.encoding, 'ucs2');
      expect(r.voice!.messageId, 'm1');
    });
  });
}
