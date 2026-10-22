// Message status, hosted OTP, management API, push device registry,
// WhatsApp / tracking payloads, idempotency and webhook events: the pure
// parts (no libsodium needed).

import 'dart:convert';

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter_test/flutter_test.dart';

class _PublicTransport implements CatzTransport {
  final List<({Uri url, Map<String, String> headers, String body})> requests =
      <({Uri url, Map<String, String> headers, String body})>[];

  @override
  Future<TransportResponse> post(Uri url, Map<String, String> headers, String body) async {
    requests.add((url: url, headers: headers, body: body));
    return const TransportResponse(200, '{"success":true,"message":"ok","data":{"device_id":"d1","created":true}}');
  }
}

const String _id = '6f0c1b9e-1111-4222-8333-944455556666';

void main() {
  test('idempotency key and reference are added only when set', () {
    const SendInput base = SendInput(
      channel: Channel.email,
      type: MessageType.transactional,
      template: Template.custom,
      identity: 'hello',
      payload: SendPayload(to: 'a@b.co', subject: 's', body: 'b'),
    );
    final Map<String, dynamic> plain = buildSendPayload(base);
    expect(plain.containsKey('idempotency_key'), isFalse);
    expect(plain.containsKey('reference'), isFalse);
    final Map<String, dynamic> p = buildSendPayload(base.copyWith(idempotencyKey: 'order-42', reference: 'order 42'));
    expect(p['idempotency_key'], 'order-42');
    expect(p['reference'], 'order 42');
    expect(() => verifyPayload(base.copyWith(idempotencyKey: 'has space')), throwsA(isA<CatzValidationException>()));
    expect(() => verifyPayload(base.copyWith(reference: 'a\nb')), throwsA(isA<CatzValidationException>()));
  });

  test('tracking is Email only and sent as given', () {
    const SendInput email = SendInput(
      channel: Channel.email,
      type: MessageType.transactional,
      template: Template.custom,
      identity: 'h',
      payload: SendPayload(to: 'a@b.co', subject: 's', body: 'b', tracking: TrackingOverride(opens: false)),
    );
    verifyPayload(email);
    expect(buildSendPayload(email)['tracking'], <String, dynamic>{'opens': false});
    const SendInput sms = SendInput(
      channel: Channel.sms,
      type: MessageType.transactional,
      template: Template.custom,
      payload: SendPayload(to: '+15550100', body: 'x', tracking: TrackingOverride(opens: true)),
    );
    expect(() => verifyPayload(sms), throwsA(isA<CatzValidationException>()));
  });

  test('WhatsApp approved templates and media', () {
    const SendInput tpl = SendInput(
      channel: Channel.whatsApp,
      type: MessageType.transactional,
      template: 'order_update',
      identity: '919578456444',
      payload: SendPayload(to: '+919876543210', whatsapp: <String, Object?>{
        'language': 'en_US',
        'header': <String, Object?>{'type': 'text', 'text': '#1'},
        'body': <String>['Ravi', '#1'],
        'buttons': <Object?>[
          <String, Object?>{'index': 0, 'type': 'url', 'text': 'abc'},
        ],
      }),
    );
    verifyPayload(tpl);
    expect((buildSendPayload(tpl)['whatsapp'] as Map<String, Object?>)['language'], 'en_US');

    const SendInput media = SendInput(
      channel: Channel.whatsApp,
      type: MessageType.notification,
      template: Template.custom,
      identity: '919578456444',
      payload: SendPayload(to: '+919876543210', body: 'Invoice', whatsapp: <String, Object?>{
        'media': <String, Object?>{'type': 'document', 'link': 'https://x.example/i.pdf', 'filename': 'i.pdf'},
      }),
    );
    verifyPayload(media);

    expect(() => verifyPayload(tpl.copyWith(template: 'Order Update')), throwsA(isA<CatzValidationException>()));
    expect(
      () => verifyWhatsAppMedia(<String, Object?>{'type': 'audio', 'link': 'https://x/a', 'caption': 'no'}),
      throwsA(isA<CatzValidationException>()),
    );
    expect(() => verifyWhatsAppMedia(<String, Object?>{'type': 'image', 'link': 'http://x/a'}),
        throwsA(isA<CatzValidationException>()));
    expect(
      () => verifyWhatsAppOptions(<String, Object?>{'body': <String>['two\nlines']}),
      throwsA(isA<CatzValidationException>()),
    );
    expect(
      () => verifyWhatsAppOptions(<String, Object?>{
        'buttons': <Object?>[
          <String, Object?>{'index': 0, 'type': 'url'},
        ],
      }),
      throwsA(isA<CatzValidationException>()),
    );
  });

  test('message, OTP and device payload builders', () {
    expect(buildListMessagesPayload(recipient: '+15550100', channel: 'SMS', limit: 5),
        <String, dynamic>{'recipient': '+15550100', 'channel': 'sms', 'limit': 5});
    expect(() => buildListMessagesPayload(), throwsA(isA<CatzValidationException>()));
    expect(buildOtpStartPayload(channel: 'sms', to: '+15550100', codeLength: 8),
        <String, dynamic>{'channel': 'SMS', 'to': '+15550100', 'code_length': 8});
    expect(() => buildOtpStartPayload(channel: 'push', to: 'x'), throwsA(isA<CatzValidationException>()));
    expect(() => buildOtpStartPayload(channel: 'email', to: 'a@b.co', ttlSeconds: 5),
        throwsA(isA<CatzValidationException>()));
    expect(buildOtpVerifyPayload(verificationId: _id, code: '123 456'),
        <String, dynamic>{'verification_id': _id, 'code': '123456'});
    expect(() => buildOtpVerifyPayload(code: '1234'), throwsA(isA<CatzValidationException>()));
    expect(
      () => buildRegisterDevicePayload(publishableKey: 'pk_push_abcdef', token: 't' * 40, platform: 'tv'),
      throwsA(isA<CatzValidationException>()),
    );
    expect(CatzErrorCodes.isRetryable(CatzErrorCodes.sendingPaused), isTrue);
    expect(CatzErrorCodes.isRetryable(CatzErrorCodes.keyExpired), isFalse);
  });

  test('pushDevices posts plain JSON without an API key', () async {
    final _PublicTransport t = _PublicTransport();
    final CatzConnect catz = CatzConnect(baseUrl: 'https://api.test', transport: t);
    final Map<String, dynamic> r = await catz.pushDevices
        .register(publishableKey: 'pk_push_abcdef', token: 't' * 40, platform: 'web', userHash: 'h');
    expect(r['device_id'], 'd1');
    expect(t.requests.single.url.toString(), 'https://api.test/push/register');
    expect(t.requests.single.headers.containsKey('Authorization'), isFalse);
    expect((jsonDecode(t.requests.single.body) as Map<String, dynamic>)['user_hash'], 'h');
  });

  test('details of a refusal', () {
    final CatzApiException e =
        CatzApiException.from(400, '{"success":false,"message":"wrong","code":"otp_invalid","attempts_remaining":2}');
    expect(e.code, CatzErrorCodes.otpInvalid);
    expect(e.details!['attempts_remaining'], 2);
  });

  test('parseWebhookEvent verifies and flags test events', () {
    const String body =
        '{"id":"e1","type":"sms.delivered","created_at":"x","organization_id":"o","test":true,"data":{"message_id":"m"}}';
    // HMAC-SHA256(secret, "<t>.<body>") — computeUserHash is that HMAC.
    final String header = 't=1700000000,v1=${computeUserHash('1700000000.$body', 'whsec_test')}';
    final WebhookEvent ev = parseWebhookEvent(body, header, 'whsec_test', nowSeconds: 1700000000);
    expect(ev.type, 'sms.delivered');
    expect(ev.test, isTrue);
    expect(ev.data['message_id'], 'm');
    expect(() => parseWebhookEvent(body, header, 'other', nowSeconds: 1700000000), throwsA(isA<FormatException>()));
    expect(kWebhookEvents, contains('whatsapp.read'));
    expect(kManageOperations['keys'], contains('create'));
  });

  test('email topic is Email only and sent as given', () {
    const SendInput email = SendInput(
      channel: Channel.email,
      type: MessageType.transactional,
      template: Template.custom,
      identity: 'h',
      payload: SendPayload(to: 'a@b.co', subject: 's', body: 'b', topic: 'newsletter'),
    );
    verifyPayload(email);
    expect(buildSendPayload(email)['topic'], 'newsletter');
    expect(
      () => verifyPayload(email.copyWith(payload: const SendPayload(to: 'a@b.co', subject: 's', body: 'b', topic: 'News Letter'))),
      throwsA(isA<CatzValidationException>()),
    );
    const SendInput sms = SendInput(
      channel: Channel.sms,
      type: MessageType.transactional,
      template: Template.custom,
      payload: SendPayload(to: '+15550100', body: 'x', topic: 'newsletter'),
    );
    expect(() => verifyPayload(sms), throwsA(isA<CatzValidationException>()));
    expect(CatzErrorCodes.invalidTopic, 'invalid_topic');
    expect(CatzErrorCodes.recipientSuppressed, 'recipient_suppressed');
    expect(CatzErrorCodes.notCancelable, 'not_cancelable');
  });

  test('push broadcast / topic / sendAt', () {
    SendInput push(SendPayload p) => SendInput(
          channel: Channel.push,
          type: MessageType.notification,
          template: Template.notification,
          identity: 'my-firebase',
          payload: p,
        );
    final SendInput topic = push(SendPayload(
        body: 'Sale', push: PushOptions(topic: 'deals', sendAt: DateTime.utc(2026, 11, 2, 9))));
    verifyPayload(topic);
    final Map<String, dynamic> p = buildSendPayload(topic);
    expect(p['push'], <String, dynamic>{'topic': 'deals', 'send_at': '2026-11-02T09:00:00.000Z'});
    expect(p.containsKey('to'), isFalse);
    verifyPayload(push(const SendPayload(body: 'x', push: PushOptions(broadcast: true))));
    final String tok = 't' * 40;
    // A scheduled push to one token keeps `to`.
    expect(buildSendPayload(push(SendPayload(to: tok, body: 'x', push: PushOptions(sendAt: DateTime.utc(2026, 11, 2)))))['to'], tok);
    for (final SendPayload bad in <SendPayload>[
      SendPayload(to: tok, body: 'x', push: const PushOptions(broadcast: true)),
      const SendPayload(body: 'x', push: PushOptions(broadcast: true, topic: 'a')),
      const SendPayload(body: 'x', push: PushOptions(topic: 'a/b')),
      const SendPayload(body: 'x', deviceKey: 'k', push: PushOptions(topic: 'a')),
    ]) {
      expect(() => verifyPayload(push(bad)), throwsA(isA<CatzValidationException>()));
    }
    const SendInput emailWithPush = SendInput(
      channel: Channel.email,
      type: MessageType.transactional,
      template: Template.custom,
      identity: 'h',
      payload: SendPayload(to: 'a@b.co', subject: 's', body: 'b', push: PushOptions(broadcast: true)),
    );
    expect(() => verifyPayload(emailWithPush), throwsA(isA<CatzValidationException>()));
  });

  test('push topic, list and suppression payload builders', () {
    expect(buildListMessagesPayload(broadcastId: _id), <String, dynamic>{'broadcast_id': _id});
    expect(() => buildListMessagesPayload(broadcastId: 'x'), throwsA(isA<CatzValidationException>()));
    final String tok = 't' * 40;
    expect(
      buildPushTopicChangePayload(identity: 'my-firebase', topic: 'deals', tokens: <String>[tok], externalUserId: 'u1'),
      <String, dynamic>{'identity': 'my-firebase', 'topic': 'deals', 'tokens': <String>[tok], 'external_user_id': 'u1'},
    );
    expect(() => buildPushTopicChangePayload(identity: 'p', topic: 'deals'), throwsA(isA<CatzValidationException>()));
    expect(() => buildPushTopicChangePayload(identity: 'p', topic: 'bad topic', externalUserId: 'u'),
        throwsA(isA<CatzValidationException>()));
  });

  test('pushDevices topic subscriptions post plain JSON', () async {
    final _PublicTransport t = _PublicTransport();
    final CatzConnect catz = CatzConnect(baseUrl: 'https://api.test', transport: t);
    await catz.pushDevices.subscribeTopics(publishableKey: 'pk_push_abcdef', token: 't' * 40, topics: <String>['deals']);
    expect(t.requests.single.url.toString(), 'https://api.test/push/topics/subscribe');
    expect((jsonDecode(t.requests.single.body) as Map<String, dynamic>)['topics'], <dynamic>['deals']);
    await catz.pushDevices.unsubscribeTopics(publishableKey: 'pk_push_abcdef', token: 't' * 40, topics: <String>['deals']);
    expect(t.requests.last.url.toString(), 'https://api.test/push/topics/unsubscribe');
    expect(
      () => catz.pushDevices.subscribeTopics(publishableKey: 'pk_push_abcdef', token: 't' * 40, topics: <String>[]),
      throwsA(isA<CatzValidationException>()),
    );
  });

  test('webhook events include the cross-channel events', () {
    for (final String e in <String>[
      'email.complained',
      'email.unsubscribed',
      'push.opened',
      'sms.inbound',
      'sms.opt_out',
      'whatsapp.opt_out',
    ]) {
      expect(kWebhookEvents, contains(e));
    }
  });
}
