// App keys: the challenge → attestation → session state machine, header
// injection, retry, refresh timing and error mapping. Pure Dart: fakes for
// the plugin, the endpoints, the transport and the cipher (no libsodium, no
// device).

import 'dart:convert';

import 'package:catzconnect/catzconnect.dart';
import 'package:catzconnect/src/app/app_session.dart' show AppSessionHeaderSource, kDeviceIdStoreKey;
import 'package:catzconnect/src/app/app_session_api.dart' show mapAppKeyError;
import 'package:catzconnect/src/app/attest_platform.dart' show attestationErrorFromPlatform;
import 'package:catzconnect/src/core/crypto.dart' show EncryptedBody;
import 'package:catzconnect/src/core/http.dart';
import 'package:catzconnect/src/core/sha256.dart';
import 'package:catzconnect/src/core/sodium/sodium_backend.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fakes.dart';

const String kAppKey = 'ak_test_123';

CatzAppSessionManager manager(
  FakeAttestPlatform platform,
  FakeSessionApi api,
  FakeClock clock, {
  String? debugToken,
  String? cloudProjectNumber,
  bool releaseMode = false,
}) =>
    CatzAppSessionManager(
      api: api,
      platform: platform,
      appKey: kAppKey,
      debugToken: debugToken,
      cloudProjectNumber: cloudProjectNumber,
      clock: () => clock.now,
      releaseMode: releaseMode,
    );

Matcher attestation(String reason) =>
    throwsA(isA<CatzAttestationException>().having((CatzAttestationException e) => e.reason, 'reason', reason));

const CatzAttestDeviceInfo ios = CatzAttestDeviceInfo(platform: 'ios', appAttestSupported: true, osVersion: '18.0');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Android (Play Integrity)', () {
    test('challenge → integrity token with nonce = challenge → session', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock);

      final CatzAppSession s = await m.ensure();
      expect(s.token, 'as1.session-1');
      expect(s.platform, 'android');
      expect(s.debug, isFalse);
      expect(s.limits.perDevicePerHour, 20);
      expect(s.limits.allowedTypes, <String>['Otp']);
      expect(s.expiresAt, clock.now.add(const Duration(hours: 1)));

      expect(p.integrityRequests.single.nonce, 'challenge-1');
      expect(p.integrityRequests.single.cloudProjectNumber, '123456789012'); // from the challenge
      final Map<String, dynamic> body = api.sessionBodies.single;
      expect(body.keys.toSet(), <String>{'platform', 'challenge', 'device_id', 'android'});
      expect(body['platform'], 'android');
      expect(body['challenge'], 'challenge-1');
      expect(body['android'], <String, dynamic>{'integrity_token': 'itok-1'});
      expect(body['device_id'], matches(RegExp(r'^[A-Za-z0-9_-]{22}$')));
      expect(p.store[kDeviceIdStoreKey], body['device_id']);
    });

    test('the app\'s playCloudProjectNumber wins over the key\'s', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final CatzAppSessionManager m =
          manager(p, FakeSessionApi(now: () => clock.now), clock, cloudProjectNumber: ' 999 ');
      await m.ensure();
      expect(p.integrityRequests.single.cloudProjectNumber, '999');
    });

    test('device id is created once per install and reused', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      p.store[kDeviceIdStoreKey] = 'existing_device_id_01';
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      await manager(p, api, clock).ensure();
      await manager(p, api, clock).ensure();
      expect(api.sessionBodies.map((Map<String, dynamic> b) => b['device_id']).toSet(), <String>{'existing_device_id_01'});
    });

    test('a device-side Play Integrity error surfaces as CatzAttestationException', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform()
        ..integrity.add(CatzAttestationException('integrity_network_error', 'offline', nativeCode: -3));
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      await expectLater(manager(p, api, clock).ensure(), attestation('integrity_network_error'));
      expect(api.sessionBodies, isEmpty);
    });

    test('on an emulator a failure explains the debug token', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform(
        deviceInfo: const CatzAttestDeviceInfo(platform: 'android', emulator: true),
      );
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now)..sessionErrors.add(serverReason('device_integrity'));
      await expectLater(
        manager(p, api, clock).ensure(),
        throwsA(isA<CatzAttestationException>()
            .having((CatzAttestationException e) => e.reason, 'reason', 'emulator_requires_debug_token')
            .having((CatzAttestationException e) => e.message, 'message', contains('debugToken'))
            .having((CatzAttestationException e) => e.source, 'source', CatzAttestationSource.server)),
      );
    });

    test('challenge_invalid → a new challenge, once', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now)..sessionErrors.add(serverReason('challenge_invalid'));
      final CatzAppSession s = await manager(p, api, clock).ensure();
      expect(s.token, 'as1.session-2');
      expect(api.challenges, 2);
      expect(p.integrityRequests.map((r) => r.nonce).toList(), <String>['challenge-1', 'challenge-2']);

      final FakeSessionApi api2 = FakeSessionApi(now: () => clock.now)
        ..sessionErrors.addAll(<Exception>[serverReason('challenge_invalid'), serverReason('challenge_invalid')]);
      await expectLater(manager(FakeAttestPlatform(), api2, clock).ensure(), attestation('challenge_invalid'));
      expect(api2.challenges, 2);
    });
  });

  group('iOS (App Attest)', () {
    test('first run attests a new key, stores the key id after the server accepted it', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform(deviceInfo: ios);
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock);
      await m.ensure();

      expect(p.calls, containsAllInOrder(<String>['generateKey', 'attestKey:key1']));
      expect(p.hashes.single, sha256(utf8.encode('challenge-1')));
      final Map<String, dynamic> body = api.sessionBodies.single;
      expect(body['platform'], 'ios');
      expect(body['ios'], <String, dynamic>{'key_id': 'key1', 'attestation': base64.encode(utf8.encode('att:key1'))});
      expect(p.store.entries.where((MapEntry<String, String> e) => e.key.startsWith('ios_key_id.')).single.value, 'key1');

      // Later: an assertion with the stored key.
      await m.ensure(force: true);
      expect(p.calls.last, 'generateAssertion:key1');
      expect(api.sessionBodies.last['ios'],
          <String, dynamic>{'key_id': 'key1', 'assertion': base64.encode(utf8.encode('asr:key1'))});
      expect(p.hashes.last, sha256(utf8.encode('challenge-2')));
    });

    test('the key id is not stored when the server refuses the attestation', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform(deviceInfo: ios);
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now)..sessionErrors.add(serverReason('wrong_environment'));
      await expectLater(manager(p, api, clock).ensure(), attestation('wrong_environment'));
      expect(p.store.keys.where((String k) => k.startsWith('ios_key_id.')), isEmpty);
    });

    test('invalid_key from App Attest → new key and attestation', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform(deviceInfo: ios);
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock);
      await m.ensure(); // key1 registered
      p.assertionError = CatzAttestationException('app_attest_invalid_key', 'gone', platform: 'ios');
      await m.ensure(force: true);
      expect(p.calls.sublist(p.calls.length - 3),
          <String>['generateAssertion:key1', 'generateKey', 'attestKey:key2']);
      expect(api.sessionBodies.last['ios']['key_id'], 'key2');
      expect(api.sessionBodies.last['ios'].containsKey('attestation'), isTrue);
    });

    for (final String reason in <String>['unknown_key', 'key_exists', 'bad_signature', 'counter', 'device_mismatch']) {
      test('server $reason → discard the key, attest a new one (once)', () async {
        final FakeClock clock = FakeClock();
        final FakeAttestPlatform p = FakeAttestPlatform(deviceInfo: ios);
        final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
        final CatzAppSessionManager m = manager(p, api, clock);
        await m.ensure(); // key1

        api.sessionErrors.add(serverReason(reason));
        final CatzAppSession s = await m.ensure(force: true);
        expect(s.token, 'as1.session-3');
        expect(api.sessionBodies[1]['ios'].containsKey('assertion'), isTrue);
        expect(api.sessionBodies[2]['ios'], containsPair('key_id', 'key2'));
        expect(api.sessionBodies[2]['ios'].containsKey('attestation'), isTrue);

        // Refused again with a fresh key: no loop.
        api.sessionErrors.addAll(<Exception>[serverReason(reason), serverReason(reason)]);
        await expectLater(m.ensure(force: true), attestation(reason));
      });
    }

    test('the Simulator needs a debug token (clear error, nothing sent)', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p =
          FakeAttestPlatform(deviceInfo: const CatzAttestDeviceInfo(platform: 'ios', emulator: true));
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      await expectLater(manager(p, api, clock).ensure(), attestation('simulator_requires_debug_token'));
      expect(api.challenges, 0);
    });

    test('App Attest unsupported on the device', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform(deviceInfo: const CatzAttestDeviceInfo(platform: 'ios'));
      await expectLater(manager(p, FakeSessionApi(now: () => clock.now), clock).ensure(),
          attestation('app_attest_unsupported'));
    });
  });

  group('debug tokens and platforms', () {
    test('a debug token replaces the attestation (Simulator included)', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p =
          FakeAttestPlatform(deviceInfo: const CatzAttestDeviceInfo(platform: 'ios', emulator: true));
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSession s = await manager(p, api, clock, debugToken: ' cdt_abc ').ensure();
      expect(s.debug, isTrue);
      expect(api.sessionBodies.single.keys.toSet(), <String>{'platform', 'challenge', 'device_id', 'debug_token'});
      expect(api.sessionBodies.single['debug_token'], 'cdt_abc');
      expect(p.calls.where((String c) => c != 'info'), isEmpty);
    });

    test('a debug token is ignored in a release build: the app attests', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock, debugToken: 'cdt_abc', releaseMode: true);
      expect(m.usesDebugToken, isFalse);
      final CatzAppSession s = await m.ensure();
      expect(s.debug, isFalse);
      expect(api.sessionBodies.single.containsKey('debug_token'), isFalse);
      expect(api.sessionBodies.single['android'], <String, dynamic>{'integrity_token': 'itok-1'});
      expect(CatzAppSessionManager.effectiveDebugToken(' cdt_x ', releaseMode: false), 'cdt_x');
      expect(CatzAppSessionManager.effectiveDebugToken('cdt_x', releaseMode: true), isNull);
      expect(CatzAppSessionManager.effectiveDebugToken('  ', releaseMode: false), isNull);
    });

    test('other platforms are refused', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform(deviceInfo: const CatzAttestDeviceInfo(platform: 'macos'));
      await expectLater(manager(p, FakeSessionApi(now: () => clock.now), clock, debugToken: 'cdt_x').ensure(),
          attestation('unsupported_platform'));
    });
  });

  group('caching and refresh timing', () {
    test('refreshAt: 20 % before expiry, clamped to 10 s … 5 min', () {
      final DateTime t = DateTime.utc(2026);
      CatzAppSession s(Duration ttl) =>
          CatzAppSession(token: 't', obtainedAt: t, expiresAt: t.add(ttl), platform: 'android');
      expect(s(const Duration(hours: 1)).refreshAt, t.add(const Duration(minutes: 55)));
      expect(s(const Duration(minutes: 10)).refreshAt, t.add(const Duration(minutes: 8)));
      expect(s(const Duration(seconds: 30)).refreshAt, t.add(const Duration(seconds: 20)));
      expect(s(const Duration(seconds: 10)).refreshAt, t.add(const Duration(seconds: 5)));
    });

    test('cached until refreshAt, then renewed on the next request', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock);

      expect(await m.currentToken(), 'as1.session-1');
      clock.advance(const Duration(minutes: 54));
      expect(await m.currentToken(), 'as1.session-1');
      expect(api.challenges, 1);
      clock.advance(const Duration(minutes: 2)); // inside the 5-minute margin
      expect(await m.currentToken(), 'as1.session-2');
      expect(api.challenges, 2);
    });

    test('a failed renewal keeps the old session while it is valid', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock);
      await m.ensure();

      clock.advance(const Duration(minutes: 57));
      p.integrity.add(CatzAttestationException('integrity_network_error', 'offline'));
      expect(await m.currentToken(), 'as1.session-1');

      clock.advance(const Duration(minutes: 3)); // expired now
      p.integrity.add(CatzAttestationException('integrity_network_error', 'offline'));
      await expectLater(m.currentToken(), attestation('integrity_network_error'));
    });

    test('concurrent requests share one attestation', () async {
      final FakeClock clock = FakeClock();
      final FakeAttestPlatform p = FakeAttestPlatform();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(p, api, clock);
      final List<String> tokens = await Future.wait(<Future<String>>[m.currentToken(), m.currentToken(), m.currentToken()]);
      expect(tokens.toSet(), <String>{'as1.session-1'});
      expect(api.challenges, 1);
    });

    test('invalidate drops only the matching token', () async {
      final FakeClock clock = FakeClock();
      final FakeSessionApi api = FakeSessionApi(now: () => clock.now);
      final CatzAppSessionManager m = manager(FakeAttestPlatform(), api, clock);
      await m.ensure();
      m.invalidate('something-else');
      expect(m.current?.token, 'as1.session-1');
      m.invalidate('as1.session-1');
      expect(m.current, isNull);
      expect(await m.currentToken(), 'as1.session-2');
    });

    test('expires_in is preferred over expires_at (device clock may be wrong)', () {
      final DateTime now = DateTime.utc(2030); // a device clock years ahead
      final CatzAppSession s = CatzAppSession.fromResponse(<String, dynamic>{
        'session_token': 'as1.x',
        'expires_at': '2026-10-19T12:00:00Z',
        'expires_in': 600,
      }, now: now, platform: 'ios');
      expect(s.expiresAt, now.add(const Duration(minutes: 10)));
      final CatzAppSession t =
          CatzAppSession.fromResponse(<String, dynamic>{'session_token': 'as1.y', 'expires_at': '2030-01-01T01:00:00Z'},
              now: now, platform: 'ios');
      expect(t.expiresAt.toUtc(), DateTime.utc(2030, 1, 1, 1));
    });
  });

  group('HTTP: header injection and retry', () {
    const EncryptedBody body = EncryptedBody(nonce: 'n', ciphertext: 'c');
    const EnvValues env = EnvValues(apiKey: kAppKey, privateKey: 'p', serverPublicKey: 's');

    test('X-Catz-App-Session on every request; 401 app_session_expired → new session, retried once', () async {
      final FakeSource source = FakeSource();
      int n = 0;
      final RoutingTransport t = RoutingTransport((Sent r) {
        n++;
        if (n == 1) return jsonResponse(401, <String, dynamic>{'success': false, 'code': 'app_session_expired', 'message': 'x'});
        return jsonResponse(200, <String, dynamic>{'success': true, 'message': 'Queued'});
      });
      final CatzHttp http = CatzHttp(baseUrl: 'https://api.test', transport: t)..appSession = source;
      int rebuilt = 0;
      final Map<String, dynamic> res = await http.post('/sdk/send', body, env, rebuild: () async {
        rebuilt++;
        return const EncryptedBody(nonce: 'n2', ciphertext: 'c2');
      });
      expect(res['message'], 'Queued');
      expect(t.requests.map((Sent r) => r.headers[kAppSessionHeader]).toList(), <String>['tok-1', 'tok-2']);
      expect(t.requests.map((Sent r) => r.headers['Authorization']).toSet(), <String>{'Bearer $kAppKey'});
      expect(source.invalidated, <String>['tok-1']);
      expect(rebuilt, 1);
      expect(jsonDecode(t.requests[1].body), <String, dynamic>{'nonce': 'n2', 'ciphertext': 'c2'});
    });

    test('a second refusal is returned, not retried forever', () async {
      final FakeSource source = FakeSource();
      final RoutingTransport t = RoutingTransport(
          (Sent r) => jsonResponse(401, <String, dynamic>{'success': false, 'code': 'app_session_invalid', 'message': 'bad'}));
      final CatzHttp http = CatzHttp(baseUrl: 'https://api.test', transport: t)..appSession = source;
      await expectLater(
        http.request('/sdk/calls/get', body, env),
        throwsA(isA<CatzApiException>().having((CatzApiException e) => e.code, 'code', 'app_session_invalid')),
      );
      expect(t.requests, hasLength(2));
    });

    test('other 401s are not retried', () async {
      final FakeSource source = FakeSource();
      final RoutingTransport t =
          RoutingTransport((Sent r) => jsonResponse(401, <String, dynamic>{'success': false, 'code': 'unauthorized', 'message': 'no'}));
      final CatzHttp http = CatzHttp(baseUrl: 'https://api.test', transport: t)..appSession = source;
      await expectLater(http.post('/sdk/send', body, env), throwsA(isA<CatzApiException>()));
      expect(t.requests, hasLength(1));
      expect(source.invalidated, isEmpty);
    });

    test('server keys: no header, unchanged', () async {
      final RoutingTransport t = RoutingTransport((Sent r) => jsonResponse(200, <String, dynamic>{'success': true}));
      final CatzHttp http = CatzHttp(baseUrl: 'https://api.test', transport: t);
      await http.post('/sdk/send', body, env);
      expect(t.requests.single.headers.containsKey(kAppSessionHeader), isFalse);
    });

    test('the /sdk/app/* calls themselves carry no session', () async {
      final FakeSource source = FakeSource();
      final RoutingTransport t = RoutingTransport((Sent r) => jsonResponse(200, <String, dynamic>{'success': true}));
      final CatzHttp http = CatzHttp(baseUrl: 'https://api.test', transport: t)..appSession = source;
      await http.request('/sdk/app/challenge', body, env, withSession: false);
      expect(t.requests.single.headers.containsKey(kAppSessionHeader), isFalse);
      expect(source.asked, 0);
    });

    test('429 is a CatzRateLimitException with retryAfter and limit', () async {
      final RoutingTransport t = RoutingTransport((Sent r) => jsonResponse(429, <String, dynamic>{
            'success': false,
            'code': 'rate_limited',
            'message': 'Too many',
            'retry_after': 42,
            'limit': 'recipient',
          }));
      final CatzHttp http = CatzHttp(baseUrl: 'https://api.test', transport: t);
      await expectLater(
        http.post('/sdk/send', body, env),
        throwsA(isA<CatzRateLimitException>()
            .having((CatzRateLimitException e) => e.retryAfter, 'retryAfter', const Duration(seconds: 42))
            .having((CatzRateLimitException e) => e.limit, 'limit', 'recipient')
            .having((CatzRateLimitException e) => e.message, 'message', startsWith('HTTP 429: '))),
      );
    });
  });

  group('error mapping', () {
    test('attestation_failed + reason → CatzAttestationException from the server', () {
      final CatzException e = mapAppKeyError(CatzApiException.from(
          401, jsonEncode(<String, dynamic>{'success': false, 'code': 'attestation_failed', 'reason': 'wrong_certificate', 'message': 'Attestation failed'})));
      expect(e, isA<CatzAttestationException>());
      final CatzAttestationException a = e as CatzAttestationException;
      expect(a.reason, 'wrong_certificate');
      expect(a.source, CatzAttestationSource.server);
      expect(a.code, 'attestation_failed');
      expect(a.status, 401);
      expect(a.retryable, isFalse);
    });

    test('platform_not_configured → CatzAttestationException; others unchanged', () {
      final CatzException e = mapAppKeyError(CatzApiException.from(
          400, jsonEncode(<String, dynamic>{'success': false, 'code': 'platform_not_configured', 'message': 'iOS is not set up'})));
      expect(e, isA<CatzAttestationException>().having((CatzAttestationException a) => a.code, 'code', 'platform_not_configured'));
      final CatzApiException other = CatzApiException.from(
          403, jsonEncode(<String, dynamic>{'success': false, 'code': 'not_an_app_key', 'message': 'Use an app key'}));
      expect(identical(mapAppKeyError(other), other), isTrue);
    });

    test('PlatformException from the plugin → reason and native code', () {
      final CatzAttestationException e = attestationErrorFromPlatform(
          PlatformException(code: 'integrity_play_store_not_found', message: 'no store', details: <String, Object?>{'errorCode': -2}),
          platform: 'android');
      expect(e.reason, 'integrity_play_store_not_found');
      expect(e.nativeCode, -2);
      expect(e.source, CatzAttestationSource.device);
      expect(e.code, 'integrity_play_store_not_found');
      expect(CatzAttestationException('integrity_network_error', 'x').retryable, isTrue);
      expect(CatzAttestationException('app_attest_server_unavailable', 'x').retryable, isTrue);
      expect(CatzAttestationException('wrong_package', 'x').retryable, isFalse);
    });

    test('MethodChannelAttestPlatform: missing plugin → unsupported_platform; errors mapped', () async {
      const MethodChannel ch = MethodChannel('catzconnect/attest_test');
      final MethodChannelAttestPlatform platform = MethodChannelAttestPlatform(channel: ch);
      await expectLater(platform.info(), attestation('unsupported_platform'));

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, (MethodCall call) async {
        switch (call.method) {
          case 'info':
            return <String, Object?>{'platform': 'ios', 'emulator': false, 'appAttestSupported': true, 'osVersion': '18.1'};
          case 'generateAssertion':
            expect(call.arguments['clientDataHash'], isA<Uint8List>());
            throw PlatformException(code: 'app_attest_invalid_key', message: 'Invalid key', details: <String, Object?>{'errorCode': 3});
          case 'attestKey':
            return Uint8List.fromList(<int>[1, 2, 3]);
        }
        return null;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(ch, null));

      final CatzAttestDeviceInfo info = await platform.info();
      expect(info.platform, 'ios');
      expect(info.appAttestSupported, isTrue);
      expect(await platform.appAttestAttestKey('k', Uint8List(32)), <int>[1, 2, 3]);
      await expectLater(
        platform.appAttestGenerateAssertion('k', Uint8List(32)),
        throwsA(isA<CatzAttestationException>()
            .having((CatzAttestationException e) => e.reason, 'reason', 'app_attest_invalid_key')
            .having((CatzAttestationException e) => e.nativeCode, 'nativeCode', 3)
            .having((CatzAttestationException e) => e.platform, 'platform', 'ios')),
      );
      await expectLater(platform.appAttestGenerateKey(), attestation('app_attest_failed')); // null → error
    });
  });

  group('CatzConnect.app end to end (plain cipher)', () {
    setUp(() => CatzSodium.debugOverride(server: PlainCrypto()));
    tearDown(CatzSodium.debugReset);

    test('challenge → session → send with X-Catz-App-Session', () async {
      final FakeAttestPlatform p = FakeAttestPlatform();
      final RoutingTransport t = RoutingTransport((Sent r) {
        switch (r.url.path) {
          case '/sdk/app/challenge':
            return jsonResponse(200, <String, dynamic>{
              'success': true,
              'message': 'Success',
              'challenge': 'Q2hhbGxlbmdlQ2hhbGxlbmdlQ2hhbGxlbmdlQ2hhbGw',
              'expires_in': 300,
              'cloud_project_number': '123456789012',
            });
          case '/sdk/app/session':
            return jsonResponse(200, <String, dynamic>{
              'success': true,
              'message': 'Success',
              'session_token': 'as1.eyJ2IjoxfQ.sig',
              'expires_at': '2099-01-01T00:00:00Z',
              'expires_in': 3600,
              'debug': false,
              'limits': <String, dynamic>{'per_device_per_hour': 20, 'allowed_types': <String>['Otp'], 'allowed_templates': <String>[]},
            });
          default:
            return jsonResponse(200, <String, dynamic>{'success': true, 'message': 'Queued', 'data': <String, dynamic>{'message_id': 'm1'}});
        }
      });
      final CatzConnect catz = CatzConnect.app(
        appKey: kAppKey,
        privateKey: zeroKey,
        serverPublicKey: zeroKey,
        baseUrl: 'https://api.test/',
        transport: t,
        attestPlatform: p,
      );
      expect(catz.isAppKey, isTrue);

      final SendResponse res = await catz.send(const SendInput(
        channel: Channel.sms,
        type: MessageType.verification,
        template: Template.otp,
        payload: SendPayload(to: '+14155550100', otp: '123456'),
      ));
      expect(res.success, isTrue);

      expect(t.requests.map((Sent r) => r.url.path).toList(), <String>['/sdk/app/challenge', '/sdk/app/session', '/sdk/send']);
      for (final Sent r in t.requests) {
        expect(r.headers['Authorization'], 'Bearer $kAppKey');
      }
      expect(t.requests[0].headers.containsKey(kAppSessionHeader), isFalse);
      expect(t.requests[1].headers.containsKey(kAppSessionHeader), isFalse);
      expect(t.requests[2].headers[kAppSessionHeader], 'as1.eyJ2IjoxfQ.sig');

      expect(plainBody(t.requests[0].body), containsPair('platform', 'android'));
      expect(plainBody(t.requests[0].body)['ts'], isA<int>());
      final Map<String, dynamic> session = plainBody(t.requests[1].body);
      expect(session['challenge'], 'Q2hhbGxlbmdlQ2hhbGxlbmdlQ2hhbGxlbmdlQ2hhbGw');
      expect(session['android'], <String, dynamic>{'integrity_token': 'itok-1'});
      expect(p.integrityRequests.single.nonce, 'Q2hhbGxlbmdlQ2hhbGxlbmdlQ2hhbGxlbmdlQ2hhbGw');
      expect(catz.appSession!.current!.limits.perDevicePerHour, 20);

      // A second send reuses the session.
      await catz.send(const SendInput(
        channel: Channel.sms,
        type: MessageType.verification,
        template: Template.otp,
        payload: SendPayload(to: '+14155550100', otp: '654321'),
      ));
      expect(t.requests.map((Sent r) => r.url.path).skip(3).toList(), <String>['/sdk/send']);
    });

    test('attestation failures reach send() callers as CatzAttestationException', () async {
      final RoutingTransport t = RoutingTransport((Sent r) {
        if (r.url.path == '/sdk/app/challenge') {
          return jsonResponse(200, <String, dynamic>{'success': true, 'challenge': 'abc', 'cloud_project_number': null});
        }
        return jsonResponse(401, <String, dynamic>{
          'success': false,
          'code': 'attestation_failed',
          'reason': 'not_play_recognized',
          'message': 'The app is not recognised by Google Play',
        });
      });
      final CatzConnect catz = CatzConnect.app(
        appKey: kAppKey,
        privateKey: zeroKey,
        serverPublicKey: zeroKey,
        baseUrl: 'https://api.test',
        transport: t,
        attestPlatform: FakeAttestPlatform(),
      );
      await expectLater(
        catz.send(const SendInput(
          channel: Channel.sms,
          type: MessageType.verification,
          template: Template.otp,
          payload: SendPayload(to: '+14155550100', otp: '123456'),
        )),
        throwsA(isA<CatzAttestationException>()
            .having((CatzAttestationException e) => e.reason, 'reason', 'not_play_recognized')
            .having((CatzAttestationException e) => e.source, 'source', CatzAttestationSource.server)),
      );
      expect(t.requests.where((Sent r) => r.url.path == '/sdk/send'), isEmpty);
    });
  });
}

/// A session source that hands out tok-1, tok-2, …
class FakeSource implements AppSessionHeaderSource {
  int _n = 0;
  int asked = 0;
  String? _current;
  final List<String> invalidated = <String>[];

  @override
  Future<String> currentToken() async {
    asked++;
    return _current ??= 'tok-${++_n}';
  }

  @override
  void invalidate(String token) {
    invalidated.add(token);
    if (_current == token) _current = null;
  }
}
