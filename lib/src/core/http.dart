// Port of sdk/typescript/src/core/http.ts.

import 'dart:convert';

import '../types.dart';
import '../version.dart';
import 'crypto.dart';
import 'env.dart';
import 'errors.dart';
import 'transport.dart';

/// Posts encrypted bodies to the API with the Bearer API key.
class CatzHttp {
  CatzHttp({this.baseUrl, CatzTransport? transport, Duration timeout = const Duration(seconds: 30)})
      : _transport = transport,
        _timeout = timeout;

  /// Overrides `CATZCONNECT_BASE_URL` / the default.
  final String? baseUrl;
  CatzTransport? _transport;
  final Duration _timeout;

  CatzTransport get transport => _transport ??= defaultTransport(timeout: _timeout);

  Uri _url(String path) => Uri.parse('${resolveBaseUrl(baseUrl)}$path');

  Map<String, String> _headers(String apiKey, {required bool accept}) => <String, String>{
        'Content-Type': 'application/json',
        if (accept) 'Accept': 'application/json',
        'Authorization': 'Bearer $apiKey',
        'User-Agent': kCatzConnectUserAgent,
      };

  /// What `send()` uses: non-2xx throws a [CatzApiException] whose message
  /// is `HTTP <status>: <body>`; a 2xx answer is decoded and returned as is.
  Future<Map<String, dynamic>> post(String path, EncryptedBody body, EnvValues? env) async {
    final String apiKey = resolveApiKey(env);
    final TransportResponse res =
        await transport.post(_url(path), _headers(apiKey, accept: false), jsonEncode(body.toJson()));
    if (!res.ok) {
      // Message unchanged ("HTTP <status>: <body>"); status and the server's
      // `code` are available on the error too.
      throw CatzApiException(res.status, 'HTTP ${res.status}: ${res.body}', res.body,
          code: CatzApiException.from(res.status, res.body).code);
    }
    final Object? json = jsonDecode(res.body);
    return json is Map ? Map<String, dynamic>.from(json) : <String, dynamic>{'data': json};
  }

  /// What `calls.*` uses: non-2xx answers, and 2xx answers with
  /// `success: false`, throw a [CatzApiException] built from the body.
  Future<Map<String, dynamic>> request(String path, EncryptedBody body, EnvValues? env) async {
    final String apiKey = resolveApiKey(env);
    final TransportResponse res =
        await transport.post(_url(path), _headers(apiKey, accept: true), jsonEncode(body.toJson()));
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
