// Fakes for the app-key tests: the native attestation side, the two
// /sdk/app/* endpoints, a transport and a no-op cipher.

import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:catzconnect/catzconnect.dart';
import 'package:catzconnect/src/core/sodium/crypto_backend.dart';

/// Records every native call; behaviour is set per test.
class FakeAttestPlatform implements CatzAttestPlatform {
  FakeAttestPlatform({
    this.deviceInfo = const CatzAttestDeviceInfo(platform: 'android'),
  });

  CatzAttestDeviceInfo deviceInfo;
  final Map<String, String> store = <String, String>{};
  final List<String> calls = <String>[];

  /// Android: answers for requestIntegrityToken (a String or an Exception).
  final Queue<Object> integrity = Queue<Object>();
  final List<({String nonce, String? cloudProjectNumber})> integrityRequests =
      <({String nonce, String? cloudProjectNumber})>[];

  /// iOS behaviour.
  int _keys = 0;
  final List<Uint8List> hashes = <Uint8List>[];
  Object? assertionError; // thrown by the next generateAssertion, then cleared
  Object? attestError;

  @override
  Future<CatzAttestDeviceInfo> info() async {
    calls.add('info');
    return deviceInfo;
  }

  @override
  Future<String?> read(String key) async => store[key];

  @override
  Future<void> write(String key, String value) async => store[key] = value;

  @override
  Future<void> remove(String key) async => store.remove(key);

  @override
  Future<String> requestIntegrityToken({required String nonce, String? cloudProjectNumber}) async {
    calls.add('requestIntegrityToken');
    integrityRequests.add((nonce: nonce, cloudProjectNumber: cloudProjectNumber));
    final Object next = integrity.isEmpty ? 'itok-${integrityRequests.length}' : integrity.removeFirst();
    if (next is Exception) throw next;
    return next as String;
  }

  @override
  Future<String> appAttestGenerateKey() async {
    calls.add('generateKey');
    _keys++;
    return 'key$_keys';
  }

  @override
  Future<Uint8List> appAttestAttestKey(String keyId, Uint8List clientDataHash) async {
    calls.add('attestKey:$keyId');
    hashes.add(clientDataHash);
    final Object? e = attestError;
    if (e != null) {
      attestError = null;
      throw e;
    }
    return Uint8List.fromList(utf8.encode('att:$keyId'));
  }

  @override
  Future<Uint8List> appAttestGenerateAssertion(String keyId, Uint8List clientDataHash) async {
    calls.add('generateAssertion:$keyId');
    hashes.add(clientDataHash);
    final Object? e = assertionError;
    if (e != null) {
      assertionError = null;
      throw e;
    }
    return Uint8List.fromList(utf8.encode('asr:$keyId'));
  }
}

/// The /sdk/app/* endpoints in memory.
class FakeSessionApi implements CatzAppSessionApi {
  FakeSessionApi({required this.now});

  DateTime Function() now;
  int challenges = 0;
  String? cloudProjectNumber = '123456789012';
  int expiresIn = 3600;
  final List<Map<String, dynamic>> sessionBodies = <Map<String, dynamic>>[];

  /// Errors thrown by the next session calls, in order (then success).
  final Queue<Exception> sessionErrors = Queue<Exception>();

  @override
  Future<CatzAppChallenge> challenge(String platform) async {
    challenges++;
    return CatzAppChallenge(challenge: 'challenge-$challenges', expiresIn: 300, cloudProjectNumber: cloudProjectNumber);
  }

  @override
  Future<CatzAppSession> session(Map<String, dynamic> body, {required String platform}) async {
    sessionBodies.add(body);
    if (sessionErrors.isNotEmpty) throw sessionErrors.removeFirst();
    return CatzAppSession.fromResponse(<String, dynamic>{
      'success': true,
      'session_token': 'as1.session-${sessionBodies.length}',
      'expires_in': expiresIn,
      'debug': body.containsKey('debug_token'),
      'limits': <String, dynamic>{'per_device_per_hour': 20, 'allowed_types': <String>['Otp']},
    }, now: now(), platform: platform);
  }
}

CatzAttestationException serverReason(String reason) => CatzAttestationException(reason, 'refused: $reason',
    source: CatzAttestationSource.server, status: 401);

/// A clock the test moves by hand.
class FakeClock {
  FakeClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 10, 19, 12);
  DateTime now;
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

/// "Encryption" that leaves the JSON readable: seal/open are the identity.
class PlainCrypto implements ServerCrypto {
  @override
  Uint8List deriveKey(Uint8List clientPrivateKey, Uint8List serverPublicKey) => Uint8List(32);

  @override
  Uint8List open(Uint8List cipherText, Uint8List nonce, Uint8List key) => cipherText;

  @override
  Uint8List randomNonce() => Uint8List(12);

  @override
  Uint8List seal(Uint8List message, Uint8List nonce, Uint8List key) => message;
}

/// One recorded request.
typedef Sent = ({Uri url, Map<String, String> headers, String body});

/// A transport that answers with a handler and records requests.
class RoutingTransport implements CatzTransport {
  RoutingTransport(this.handler);

  final TransportResponse Function(Sent request) handler;
  final List<Sent> requests = <Sent>[];

  @override
  Future<TransportResponse> post(Uri url, Map<String, String> headers, String body) async {
    final Sent r = (url: url, headers: Map<String, String>.from(headers), body: body);
    requests.add(r);
    return handler(r);
  }
}

/// The decrypted body of a request sent with [PlainCrypto].
Map<String, dynamic> plainBody(String body) {
  final Map<String, dynamic> env = jsonDecode(body) as Map<String, dynamic>;
  return jsonDecode(utf8.decode(base64.decode(env['ciphertext'] as String))) as Map<String, dynamic>;
}

TransportResponse jsonResponse(int status, Object body) => TransportResponse(status, jsonEncode(body));

/// 32 zero bytes, base64 — a well-formed key for PlainCrypto.
final String zeroKey = base64.encode(Uint8List(32));
