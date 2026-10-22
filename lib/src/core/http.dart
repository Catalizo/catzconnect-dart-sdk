// Port of sdk/typescript/src/core/http.ts.

import 'dart:convert';

import '../app/app_session.dart' show AppSessionHeaderSource, kAppSessionHeader, kAppSessionRetryCodes;
import '../types.dart';
import '../version.dart';
import 'crypto.dart';
import 'env.dart';
import 'errors.dart';
import 'transport.dart';

/// Rebuilds (re-encrypts) a request body for a retry, so the retried request
/// gets a fresh nonce and `ts`.
typedef BodyBuilder = Future<EncryptedBody> Function();

/// Posts encrypted bodies to the API with the Bearer API key.
///
/// With an app key ([appSession] set by `CatzConnect.app`), every request
/// also carries `X-Catz-App-Session`; after a 401 `app_session_expired` /
/// `app_session_invalid` / `app_session_required` the session is renewed and
/// the request is sent once more.
class CatzHttp {
  CatzHttp({
    this.baseUrl,
    CatzTransport? transport,
    Duration timeout = const Duration(seconds: 30),
    this.allowInsecureHttp = false,
  })
      // ignore: prefer_initializing_formals
      : _transport = transport,
        // ignore: prefer_initializing_formals
        _timeout = timeout;

  /// Overrides `CATZCONNECT_BASE_URL` / the default.
  final String? baseUrl;

  /// Accept a plain `http://` base URL to a non-local host.
  final bool allowInsecureHttp;
  CatzTransport? _transport;
  final Duration _timeout;

  /// App keys: where the `X-Catz-App-Session` value comes from. Null for
  /// server keys (no header, behaviour unchanged).
  AppSessionHeaderSource? appSession;

  CatzTransport get transport => _transport ??= defaultTransport(timeout: _timeout);

  Uri _url(String path) => Uri.parse('${resolveBaseUrl(baseUrl, allowInsecureHttp: allowInsecureHttp)}$path');

  Map<String, String> _headers(String apiKey, {required bool accept, String? session, Map<String, String>? extra}) =>
      <String, String>{
        ...?extra,
        'Content-Type': 'application/json',
        if (accept) 'Accept': 'application/json',
        'Authorization': 'Bearer $apiKey',
        'User-Agent': kCatzConnectUserAgent,
        kAppSessionHeader: ?session,
      };

  static bool _isSessionRefusal(TransportResponse res) {
    if (res.status != 401) return false;
    final String? code = CatzApiException.from(res.status, res.body).code;
    return code != null && kAppSessionRetryCodes.contains(code);
  }

  /// Sends one request; with an app session, adds the header and retries
  /// once after a session refusal. [withSession] false is for the
  /// `/sdk/app/*` calls that obtain the session.
  Future<TransportResponse> _send(
    String path,
    EncryptedBody body,
    EnvValues? env, {
    required bool accept,
    BodyBuilder? rebuild,
    bool withSession = true,
    Map<String, String>? extraHeaders,
  }) async {
    final String apiKey = resolveApiKey(env);
    final AppSessionHeaderSource? source = withSession ? appSession : null;
    String? token = source == null ? null : await source.currentToken();
    TransportResponse res = await transport.post(
        _url(path), _headers(apiKey, accept: accept, session: token, extra: extraHeaders), jsonEncode(body.toJson()));
    if (source != null && token != null && _isSessionRefusal(res)) {
      source.invalidate(token);
      token = await source.currentToken();
      final EncryptedBody again = rebuild == null ? body : await rebuild();
      res = await transport.post(_url(path), _headers(apiKey, accept: accept, session: token, extra: extraHeaders),
          jsonEncode(again.toJson()));
    }
    return res;
  }

  /// POSTs plain JSON without an API key (the public push device endpoints,
  /// authorised by the project's publishable key). Non-2xx answers and
  /// `success: false` throw a [CatzApiException].
  Future<Map<String, dynamic>> postPublic(String path, Map<String, dynamic> body) async {
    final TransportResponse res = await transport.post(
      _url(path),
      <String, String>{
        'Content-Type': 'application/json',
        'Accept': 'application/json',
        'User-Agent': kCatzConnectUserAgent,
      },
      jsonEncode(body),
    );
    if (!res.ok) throw CatzApiException.from(res.status, res.body);
    final Object? json = jsonDecode(res.body);
    if (json is Map && json['success'] == false) throw CatzApiException.from(res.status, res.body);
    return json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{'data': json};
  }

  /// What `send()` uses: non-2xx throws a [CatzApiException] whose message
  /// is `HTTP <status>: <body>`; a 2xx answer is decoded and returned as is.
  Future<Map<String, dynamic>> post(String path, EncryptedBody body, EnvValues? env,
      {BodyBuilder? rebuild, Map<String, String>? extraHeaders}) async {
    final TransportResponse res =
        await _send(path, body, env, accept: false, rebuild: rebuild, extraHeaders: extraHeaders);
    if (!res.ok) {
      // Message unchanged ("HTTP <status>: <body>"); status and the server's
      // `code` are available on the error too (a 429 is a
      // CatzRateLimitException with retryAfter).
      final CatzApiException parsed = CatzApiException.from(res.status, res.body);
      if (parsed is CatzRateLimitException) {
        throw CatzRateLimitException(res.status, 'HTTP ${res.status}: ${res.body}', res.body, code: parsed.code);
      }
      throw CatzApiException(res.status, 'HTTP ${res.status}: ${res.body}', res.body, code: parsed.code);
    }
    final Object? json = jsonDecode(res.body);
    return json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{'data': json};
  }

  /// What `calls.*` and the app-key calls use: non-2xx answers, and 2xx
  /// answers with `success: false`, throw a [CatzApiException] built from the
  /// body.
  Future<Map<String, dynamic>> request(
    String path,
    EncryptedBody body,
    EnvValues? env, {
    BodyBuilder? rebuild,
    bool withSession = true,
  }) async {
    final TransportResponse res =
        await _send(path, body, env, accept: true, rebuild: rebuild, withSession: withSession);
    if (!res.ok) {
      throw CatzApiException.from(res.status, res.body);
    }
    Object? json;
    try {
      json = jsonDecode(res.body);
    } on FormatException {
      final String head = res.body.length > 200 ? res.body.substring(0, 200) : res.body;
      throw CatzApiException(res.status, 'The server sent a response that is not JSON: $head', res.body);
    }
    if (json is Map && json['success'] == false) {
      throw CatzApiException.from(res.status, res.body);
    }
    return json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{'data': json};
  }
}
