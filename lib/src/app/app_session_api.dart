// The two app-key endpoints over the same transport as /sdk/send: Bearer app
// key, encrypted {nonce, ciphertext} body, plain JSON answer.

import 'dart:convert';

import '../core/crypto.dart';
import '../core/env.dart';
import '../core/errors.dart';
import '../core/http.dart';
import '../types.dart';
import 'app_session.dart';

/// [CatzAppSessionApi] over HTTP: `POST /sdk/app/challenge` and
/// `POST /sdk/app/session`.
class HttpAppSessionApi implements CatzAppSessionApi {
  HttpAppSessionApi(this._http, this._env, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;

  final CatzHttp _http;
  final EnvValues _env;
  final DateTime Function() _clock;

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, String platform) async {
    final ResolvedKeys keys = resolveKeys(_env);
    final EncryptedBody enc = await encryptPayload(body, keys);
    try {
      final Map<String, dynamic> res = await _http.request(path, enc, _env, withSession: false);
      return await openResponse(res, keys);
    } on CatzApiException catch (e) {
      throw mapAppKeyError(e, platform: platform);
    }
  }

  @override
  Future<CatzAppChallenge> challenge(String platform) async {
    final Map<String, dynamic> res = await _post('/sdk/app/challenge', <String, dynamic>{'platform': platform}, platform);
    return CatzAppChallenge.fromResponse(res);
  }

  @override
  Future<CatzAppSession> session(Map<String, dynamic> body, {required String platform}) async {
    final Map<String, dynamic> res = await _post('/sdk/app/session', body, platform);
    return CatzAppSession.fromResponse(res, now: _clock(), platform: platform);
  }
}

/// `attestation_failed` (with `reason`) and `platform_not_configured` become
/// a [CatzAttestationException] from the server; everything else is returned
/// unchanged (a [CatzRateLimitException] for 429, `not_an_app_key`, …).
CatzException mapAppKeyError(CatzApiException e, {String? platform}) {
  if (e.code == 'attestation_failed') {
    String reason = 'attestation_failed';
    try {
      final Object? j = jsonDecode(e.body);
      if (j is Map) {
        final Object? r = j['reason'] ?? (j['data'] is Map ? (j['data'] as Map)['reason'] : null);
        if (r is String && r.isNotEmpty) reason = r;
      }
    } on FormatException {
      // keep the generic reason
    }
    return CatzAttestationException(reason, e.message,
        source: CatzAttestationSource.server, platform: platform, status: e.status, body: e.body, cause: e);
  }
  if (e.code == 'platform_not_configured') {
    return CatzAttestationException('platform_not_configured', e.message,
        source: CatzAttestationSource.server,
        platform: platform,
        status: e.status,
        body: e.body,
        cause: e,
        serverCode: 'platform_not_configured');
  }
  return e;
}
