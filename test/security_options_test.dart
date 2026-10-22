import 'package:catzconnect/catzconnect.dart';
import 'package:catzconnect/src/calls/client.dart' show buildRtcConfiguration;
import 'package:catzconnect/src/core/env.dart' show checkBaseUrl, resolveBaseUrl;
import 'package:flutter_test/flutter_test.dart';

/// 1.7.0: https-only base URLs, relay-only ICE, redacted EnvValues.
void main() {
  group('base URL', () {
    test('https is accepted, trailing slash dropped', () {
      expect(resolveBaseUrl('https://api.example.com/'), 'https://api.example.com');
    });

    test('http to a remote host is refused unless allowed', () {
      expect(() => resolveBaseUrl('http://api.example.com'), throwsA(isA<CatzException>()));
      expect(() => resolveBaseUrl('http://localhost.example.com'), throwsA(isA<CatzException>()));
      expect(resolveBaseUrl('http://api.example.com', allowInsecureHttp: true), 'http://api.example.com');
    });

    test('http to localhost-like hosts is accepted', () {
      for (final String u in <String>[
        'http://localhost:8080',
        'http://127.0.0.1:8080',
        'http://[::1]:8080',
        'http://10.0.2.2:8080',
      ]) {
        expect(resolveBaseUrl(u), u);
      }
    });

    test('other schemes and garbage are refused', () {
      expect(() => checkBaseUrl('ftp://api.example.com'), throwsA(isA<CatzException>()));
      expect(() => checkBaseUrl('api.example.com'), throwsA(isA<CatzException>()));
    });

    test('call client: ws:// only to local hosts or with allowInsecureHttp', () {
      expect(() => CatzCallClient(token: 't', url: 'ws://rtc.example.com/rtc/v1/ws'), throwsArgumentError);
      CatzCallClient(token: 't', url: 'ws://127.0.0.1:8080/rtc/v1/ws');
      CatzCallClient(token: 't', url: 'ws://rtc.example.com/rtc/v1/ws', allowInsecureHttp: true);
      CatzCallClient(token: 't');
    });
  });

  group('relay-only ICE', () {
    const List<IceServer> ice = <IceServer>[
      IceServer(urls: <String>['turn:turn.test:3478'], username: 'u', credential: 'c'),
    ];

    test('default policy is all, rtcConfig may change it', () {
      expect(buildRtcConfiguration(extra: const <String, dynamic>{}, relayOnly: false, iceServers: ice)['iceTransportPolicy'],
          'all');
      expect(
          buildRtcConfiguration(
              extra: const <String, dynamic>{'iceTransportPolicy': 'relay'}, relayOnly: false, iceServers: ice)['iceTransportPolicy'],
          'relay');
    });

    test('relayOnly forces relay over rtcConfig and keeps the ICE servers', () {
      final Map<String, dynamic> cfg = buildRtcConfiguration(
          extra: const <String, dynamic>{'iceTransportPolicy': 'all'}, relayOnly: true, iceServers: ice);
      expect(cfg['iceTransportPolicy'], 'relay');
      expect((cfg['iceServers'] as List<dynamic>).length, 1);
    });

    test('client option', () {
      expect(CatzCallClient(token: 't').relayOnly, isFalse);
      expect(CatzCallClient(token: 't', relayOnly: true).relayOnly, isTrue);
    });
  });

  test('EnvValues.toString never prints the API key or the private key', () {
    const EnvValues env = EnvValues(
      apiKey: 'live_abcdefghijklmnopqrstuvwxyz',
      privateKey: 'PRIVATEKEYBASE64SECRET==',
      serverPublicKey: 'SERVERPUB==',
    );
    final String s = env.toString();
    expect(s, isNot(contains('abcdefghijklmnopqrstuvwxyz')));
    expect(s, isNot(contains('PRIVATEKEYBASE64SECRET')));
    expect(s, contains('SERVERPUB=='));
  });
}
