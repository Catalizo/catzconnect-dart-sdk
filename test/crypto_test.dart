// Encryption, response decryption, the full send()/calls flows and push
// opening, against fixed vectors produced by the TypeScript SDK. Needs a
// libsodium on the host (see support/host_sodium.dart); skipped otherwise.

import 'dart:convert';
import 'dart:typed_data';

import 'package:catzconnect/catzconnect.dart';
import 'package:catzconnect/src/core/base64.dart';
import 'package:catzconnect/src/core/crypto.dart';
import 'package:catzconnect/src/core/env.dart';
import 'package:catzconnect/src/core/sodium/sodium_backend.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_sodium.dart';

/// Records requests and answers from a queue.
class FakeTransport implements CatzTransport {
  final List<({Uri url, Map<String, String> headers, String body})> requests =
      <({Uri url, Map<String, String> headers, String body})>[];
  final List<TransportResponse> responses = <TransportResponse>[];

  void answer(int status, Object body) =>
      responses.add(TransportResponse(status, body is String ? body : jsonEncode(body)));

  @override
  Future<TransportResponse> post(Uri url, Map<String, String> headers, String body) async {
    requests.add((url: url, headers: headers, body: body));
    return responses.removeAt(0);
  }
}

Future<void> main() async {
  final Map<String, dynamic> v = loadVectors();
  final Map<String, dynamic> keys = v['keys'] as Map<String, dynamic>;
  final HostSodium? host = await installHostSodium();
  final String? skip = host == null ? kNoSodium : null;

  final EnvValues env = EnvValues(
    apiKey: keys['api_key'] as String,
    privateKey: keys['client_private'] as String,
    serverPublicKey: keys['server_public'] as String,
  );
  final ResolvedKeys clientKeys = resolveKeys(env);
  final Uint8List fixedNonce = decodeBase64Lenient(v['fixed_nonce'] as String);
  final int fixedTs = v['fixed_ts'] as int;

  // What the server does: the same key from its side of the ECDH.
  Uint8List serverKey() =>
      host!.crypto.deriveKey(decodeKey32(keys['server_private'] as String), decodeKey32(keys['client_public'] as String));

  Map<String, dynamic> serverOpen(String requestBody) {
    final Map<String, dynamic> b = jsonDecode(requestBody) as Map<String, dynamic>;
    final Uint8List plain = host!.crypto.open(
      decodeBase64Lenient(b['ciphertext'] as String),
      decodeBase64Lenient(b['nonce'] as String),
      serverKey(),
    );
    return jsonDecode(utf8.decode(plain)) as Map<String, dynamic>;
  }

  Map<String, dynamic> withoutTs(Map<String, dynamic> m) => Map<String, dynamic>.from(m)..remove('ts');

  setUp(() async {
    await installHostSodium();
  });

  group('key derivation and request encryption', () {
    test('X25519 → BLAKE2b → BLAKE2b(master ‖ label) gives the TypeScript key, from both sides', () {
      final Uint8List k = host!.crypto
          .deriveKey(decodeKey32(keys['client_private'] as String), decodeKey32(keys['server_public'] as String));
      expect(encodeBase64(k), keys['derived_key']);
      expect(encodeBase64(serverKey()), keys['derived_key']);
    }, skip: skip);

    for (final Object? raw in v['sends'] as List<Object?>) {
      final Map<String, dynamic> s = raw! as Map<String, dynamic>;
      test('${s['name']}: fixed nonce + ts → the TypeScript ciphertext', () async {
        final SendInput input = SendInput.fromJson(s['input'] as Map<String, dynamic>);
        final EncryptedBody enc =
            await encryptPayload(buildSendPayload(input), clientKeys, nonce: fixedNonce, timestampMs: fixedTs);
        expect(enc.nonce, s['nonce']);
        expect(enc.ciphertext, s['ciphertext']);
        // And the plaintext is exactly what TypeScript encrypted.
        final Uint8List plain = host!.crypto.open(
            decodeBase64Lenient(enc.ciphertext), decodeBase64Lenient(enc.nonce), serverKey());
        expect(utf8.decode(plain), s['plaintext']);
      }, skip: skip);
    }

    test('a random nonce is 12 bytes and differs each time', () async {
      final EncryptedBody a = await encryptPayload(<String, dynamic>{'x': 1}, clientKeys);
      final EncryptedBody b = await encryptPayload(<String, dynamic>{'x': 1}, clientKeys);
      expect(decodeBase64Lenient(a.nonce).length, 12);
      expect(a.nonce, isNot(b.nonce));
    }, skip: skip);

    test('keys are read leniently (whitespace, URL-safe, no padding) and must be 32 bytes', () async {
      final String messy = '  ${(keys['client_private'] as String).replaceAll('=', '').replaceAll('+', '-').replaceAll('/', '_')}\n';
      final EncryptedBody enc = await encryptPayload(
        <String, dynamic>{'a': 'b'},
        ResolvedKeys(privateKey: messy, serverPublicKey: keys['server_public'] as String),
        nonce: fixedNonce,
        timestampMs: fixedTs,
      );
      final EncryptedBody ref = await encryptPayload(<String, dynamic>{'a': 'b'}, clientKeys,
          nonce: fixedNonce, timestampMs: fixedTs);
      expect(enc.ciphertext, ref.ciphertext);

      await expectLater(
        encryptPayload(<String, dynamic>{}, const ResolvedKeys(privateKey: 'AAAA', serverPublicKey: 'AAAA')),
        throwsA(isA<CatzException>().having((CatzException e) => e.message, 'message', contains('expected 32 bytes'))),
      );
    }, skip: skip);
  });

  group('send()', () {
    for (final Object? raw in v['sends'] as List<Object?>) {
      final Map<String, dynamic> s = raw! as Map<String, dynamic>;
      test('${s['name']}: URL, headers and decrypted body', () async {
        final FakeTransport t = FakeTransport()..answer(200, s['response'] as Object);
        final CatzConnect catz = CatzConnect(env: env, baseUrl: v['base_url_env'] as String, transport: t);
        final SendResponse res = await catz.send(SendInput.fromJson(s['input'] as Map<String, dynamic>));
        expect(res.success, isTrue);
        expect(res.raw, s['response']);

        final ({Uri url, Map<String, String> headers, String body}) r = t.requests.single;
        expect(r.url.toString(), s['url']);
        expect(r.headers['Authorization'], s['authorization']);
        expect(r.headers['Content-Type'], s['content_type']);
        expect(r.headers['User-Agent'], 'catzconnect-dart-sdk/$kCatzConnectVersion');
        expect(r.headers.containsKey('Accept'), isFalse);
        final Map<String, dynamic> body = jsonDecode(r.body) as Map<String, dynamic>;
        expect(body.keys.toList(), <String>['nonce', 'ciphertext']);
        final Map<String, dynamic> opened = serverOpen(r.body);
        expect(opened['ts'], isA<int>());
        expect(withoutTs(opened), withoutTs(jsonDecode(s['plaintext'] as String) as Map<String, dynamic>));
      }, skip: skip);
    }

    test('a refusal keeps status, code and body, with the TypeScript message', () async {
      final Map<String, dynamic> e = v['send_error'] as Map<String, dynamic>;
      final FakeTransport t = FakeTransport()..answer(e['status'] as int, e['body'] as String);
      final CatzConnect catz = CatzConnect(env: env, transport: t);
      final Map<String, dynamic> smsOtp =
          (v['sends'] as List<Object?>).cast<Map<String, dynamic>>().firstWhere((Map<String, dynamic> s) => s['name'] == 'sms_otp');
      await expectLater(
        catz.send(SendInput.fromJson(smsOtp['input'] as Map<String, dynamic>)),
        throwsA(isA<CatzApiException>()
            .having((CatzApiException x) => x.message, 'message', e['message'])
            .having((CatzApiException x) => x.status, 'status', e['status'])
            .having((CatzApiException x) => x.code, 'code', e['code'])
            .having((CatzApiException x) => x.body, 'body', e['body'])),
      );
    }, skip: skip);

    test('an empty API key is refused after encryption, like TypeScript', () async {
      final CatzConnect catz = CatzConnect(
        env: EnvValues(apiKey: '  ', privateKey: env.privateKey, serverPublicKey: env.serverPublicKey),
        transport: FakeTransport(),
      );
      await expectLater(
        catz.send(const SendInput(
          channel: Channel.sms,
          type: MessageType.verification,
          template: Template.otp,
          payload: SendPayload(to: '+14155550100', otp: '1234'),
        )),
        throwsA(isA<CatzException>().having((CatzException x) => x.message, 'message', contains('Missing API key'))),
      );
    }, skip: skip);

    test('defaultLanguage fills in a missing language; an explicit one wins', () async {
      final FakeTransport t = FakeTransport()
        ..answer(200, <String, dynamic>{'success': true, 'message': 'ok'})
        ..answer(200, <String, dynamic>{'success': true, 'message': 'ok'});
      final CatzConnect catz = CatzConnect(env: env, transport: t, defaultLanguage: 'de-AT');
      expect(catz.defaultLanguage, 'de');
      const SendInput input = SendInput(
        channel: Channel.email,
        type: MessageType.verification,
        template: Template.otp,
        identity: 'a@b.co',
        payload: SendPayload(to: 'u@x.co', otp: '123456'),
      );
      await catz.send(input);
      await catz.send(input.copyWith(language: 'ja-JP'));
      expect(serverOpen(t.requests[0].body)['language'], 'de');
      expect(serverOpen(t.requests[1].body)['language'], 'ja');
      await expectLater(catz.send(input.copyWith(language: 'fr')), throwsA(isA<CatzValidationException>()));
      expect(t.requests, hasLength(2));
    }, skip: skip);
  });

  group('calls', () {
    final Map<String, dynamic> calls = v['calls'] as Map<String, dynamic>;

    test('create posts the encrypted body with the send() headers plus Accept', () async {
      final Map<String, dynamic> c = calls['create_request'] as Map<String, dynamic>;
      final FakeTransport t = FakeTransport()..answer(200, c['response'] as Object);
      final CatzConnect catz = CatzConnect(env: env, baseUrl: v['base_url_env'] as String, transport: t);
      final Call call = await catz.calls.create(const CreateCallInput(
        mode: CallMode.audio,
        from: 'alice',
        to: <String>['bob', 'carol'],
        engine: ' catz ',
        ring: false,
        metadata: <String, Object?>{
          'order': 'A-1042',
          'n': 7,
          'nested': <String, Object?>{'ok': true},
        },
        maxParticipants: 4,
      ));
      final ({Uri url, Map<String, String> headers, String body}) r = t.requests.single;
      expect(r.url.toString(), c['url']);
      expect(r.headers['Authorization'], c['authorization']);
      expect(r.headers['Accept'], c['accept']);
      expect(withoutTs(serverOpen(r.body)), withoutTs(jsonDecode(c['plaintext'] as String) as Map<String, dynamic>));

      final Map<String, dynamic> expected = c['result'] as Map<String, dynamic>;
      expect(call.id, expected['id']);
      expect(call.status, CallStatus.ringing);
      expect(call.mode, CallMode.video);
      expect(call.participants.length, 2);
      expect(call.participants.first.connection, 'direct');
      expect(call.metadata, expected['metadata']);
    }, skip: skip);

    test('token: a sealed data envelope is opened with the request key', () async {
      final Map<String, dynamic> c = calls['token_request'] as Map<String, dynamic>;
      final FakeTransport t = FakeTransport()..answer(200, c['response'] as Object);
      final CatzConnect catz = CatzConnect(env: env, transport: t);
      final CallToken tok = await catz.calls.token('alice', ttlSeconds: 600);
      expect(tok.toJson(), c['result']);
      expect(withoutTs(serverOpen(t.requests.single.body)),
          withoutTs(jsonDecode(c['plaintext'] as String) as Map<String, dynamic>));
    }, skip: skip);

    test('get: a sealed top-level response is opened', () async {
      final Map<String, dynamic> c = calls['get_request'] as Map<String, dynamic>;
      final FakeTransport t = FakeTransport()..answer(200, c['response'] as Object);
      final CatzConnect catz = CatzConnect(env: env, transport: t);
      final Call call = await catz.calls.get(' c1 ');
      expect(call.id, c['result_id']);
      expect(call.status.name, c['result_status']);
      expect(withoutTs(serverOpen(t.requests.single.body)),
          withoutTs(jsonDecode(c['plaintext'] as String) as Map<String, dynamic>));
    }, skip: skip);

    test('end', () async {
      final Map<String, dynamic> c = calls['end_request'] as Map<String, dynamic>;
      final FakeTransport t = FakeTransport()..answer(200, <String, dynamic>{'success': true, 'message': 'Call ended'});
      final CatzConnect catz = CatzConnect(env: env, transport: t);
      final EndCallResult res = await catz.calls.end('c1', reason: '  done ');
      final Map<String, dynamic> expected = c['result'] as Map<String, dynamic>;
      expect(res.success, expected['success']);
      expect(res.message, expected['message']);
      expect(withoutTs(serverOpen(t.requests.single.body)),
          withoutTs(jsonDecode(c['plaintext'] as String) as Map<String, dynamic>));
    }, skip: skip);

    test('refusals: status, code, body and message as in TypeScript', () async {
      for (final Object? raw in calls['errors'] as List<Object?>) {
        final Map<String, dynamic> c = raw! as Map<String, dynamic>;
        final Map<String, dynamic> e = c['error'] as Map<String, dynamic>;
        final FakeTransport t = FakeTransport()..answer(c['status'] as int, c['body'] as String);
        final CatzConnect catz = CatzConnect(env: env, transport: t);
        await expectLater(
          catz.calls.get('c1'),
          throwsA(isA<CatzApiException>()
              .having((CatzApiException x) => x.message, 'message', e['message'])
              .having((CatzApiException x) => x.status, 'status', e['status'])
              .having((CatzApiException x) => x.code, 'code', e['code'])
              .having((CatzApiException x) => x.body, 'body', e['body'])),
        );
      }
    }, skip: skip);

    test('a response sealed with another key is refused', () async {
      final Map<String, dynamic> c = calls['token_request'] as Map<String, dynamic>;
      final FakeTransport t = FakeTransport()..answer(200, c['response'] as Object);
      // Same client key, a different server public key → a different shared key.
      final CatzConnect catz = CatzConnect(
        env: EnvValues(apiKey: 'k', privateKey: env.privateKey, serverPublicKey: keys['client_public'] as String),
        transport: t,
      );
      await expectLater(
        catz.calls.token('alice'),
        throwsA(isA<CatzException>().having((CatzException x) => x.message, 'message',
            'The response is encrypted with a key this SDK cannot open')),
      );
    }, skip: skip);
  });

  test('a plain response is returned unchanged without loading libsodium', () async {
    CatzSodium.debugReset();
    final Map<String, dynamic> res = <String, dynamic>{'success': true, 'data': <String, dynamic>{'a': 1}};
    expect(await openResponse(res, clientKeys), same(res));
  });

  group('push', () {
    final Map<String, dynamic> push = v['push'] as Map<String, dynamic>;
    final Map<String, dynamic> dk = push['device_keys'] as Map<String, dynamic>;
    final DeviceKeys deviceKeys = DeviceKeys.fromJson(dk);

    test('openPushPayload opens what the server sealed, like TypeScript', () async {
      for (final Object? raw in push['cases'] as List<Object?>) {
        final Map<String, dynamic> c = raw! as Map<String, dynamic>;
        final PushContent opened = await openPushPayload(c['data'] as Map<String, dynamic>, deviceKeys);
        expect(opened.toJson(), c['opened']);
      }
    }, skip: skip);

    test('openPushPayload refuses another device\'s keys and unsealed data', () async {
      final Map<String, dynamic> first = (push['cases'] as List<Object?>).first! as Map<String, dynamic>;
      final DeviceKeys other = DeviceKeys.fromJson(push['other_device_keys'] as Map<String, dynamic>);
      await expectLater(openPushPayload(first['data'] as Map<String, dynamic>, other), throwsA(isA<CatzException>()));
      await expectLater(openPushPayload(<String, dynamic>{'catz_v': '1'}, deviceKeys), throwsA(isA<CatzException>()));
    }, skip: skip);

    test('generateDeviceKeys → seal → open round trip', () async {
      final DeviceKeys k = await generateDeviceKeys();
      expect(decodeBase64Lenient(k.publicKey).length, 32);
      expect(decodeBase64Lenient(k.privateKey).length, 32);
      final Uint8List sealed = host!.sumo.crypto.box.seal(
        message: Uint8List.fromList(utf8.encode(jsonEncode(<String, dynamic>{'title': 'T', 'body': 'B', 'data': <String, String>{'x': 'y'}}))),
        publicKey: decodeBase64Lenient(k.publicKey),
      );
      final PushContent c = await openPushPayload(<String, dynamic>{'catz_v': '1', 'catz_sealed': encodeBase64(sealed)}, k);
      expect(c.title, 'T');
      expect(c.body, 'B');
      expect(c.data, <String, String>{'x': 'y'});
    }, skip: skip);
  });
}
