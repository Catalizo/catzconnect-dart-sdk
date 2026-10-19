// The server SDK client: send() and calls. Port of sdk/typescript/src/index.ts.

import 'calls_api.dart';
import 'core/crypto.dart';
import 'core/env.dart';
import 'core/errors.dart';
import 'core/http.dart';
import 'core/payload.dart';
import 'core/sodium/sodium_backend.dart';
import 'core/transport.dart';
import 'types.dart';
import 'utils/language.dart';

/// Sends encrypted requests to the Catz Connect API: messages on every
/// channel with [send], and Voice & Video calls with [calls].
///
/// **Read the security note in the README before putting an API key in an
/// app**: anyone who unpacks the app can extract it. The recommended pattern
/// is to call `send()` / `calls.create()` from your backend and use only the
/// call client and push helpers in the app.
///
/// Credentials come from [env] when given (or per call), otherwise from
/// `--dart-define` / the process environment: `CATZCONNECT_API_KEY`,
/// `CATZCONNECT_PRIVATE_KEY`, `CATZCONNECT_SERVER_PUBLIC_KEY` and the
/// optional `CATZCONNECT_BASE_URL`.
///
/// Not available on Flutter web (it needs `dart:io`): [send] and [calls]
/// throw an [UnsupportedError] there.
class CatzConnect {
  CatzConnect({
    EnvValues? env,
    String? baseUrl,
    CatzTransport? transport,
    Duration timeout = const Duration(seconds: 30),
    String? defaultLanguage,
  })  : _env = env,
        defaultLanguage = defaultLanguage == null ? null : normaliseLanguage(defaultLanguage),
        _http = CatzHttp(baseUrl: baseUrl, transport: transport, timeout: timeout) {
    calls = CallsApi(_http, env);
  }

  final EnvValues? _env;
  final CatzHttp _http;

  /// The `language` (normalised, e.g. `'de'`) used by every [send] whose
  /// [SendInput.language] is `null`. Set with the `defaultLanguage`
  /// constructor argument (en, de, ja, ar, hi or a BCP-47 tag such as
  /// `'de-DE'`; anything else throws a [CatzValidationException]).
  final String? defaultLanguage;

  /// Voice & Video calls: `create`, `token`, `get`, `end`.
  late final CallsApi calls;

  /// Loads libsodium (sodium_libs) ahead of the first request, so a missing
  /// native library shows up at start-up rather than on the first send.
  /// Optional: everything loads it lazily. Safe to call more than once.
  ///
  /// On Flutter web only the push helpers' libsodium is loaded.
  static Future<void> init() async {
    await CatzSodium.box();
    try {
      await CatzSodium.server();
    } on UnsupportedError {
      // Flutter web: send() and calls are not available; push helpers are.
    }
  }

  /// Validates, encrypts and sends [input]. Returns the server's
  /// `{success, message, data}`; for SMS read `response.sms`, for Voice
  /// `response.voice`.
  ///
  /// Throws a [CatzValidationException] when the input is refused before
  /// sending, a [CatzException] for missing or malformed keys, and — when
  /// the server refuses — a [CatzApiException] whose message is
  /// `Failed to send <type>.<channel>.<template>: HTTP <status>: <body>`
  /// with [CatzException.status], [CatzException.code] and
  /// [CatzException.body] set.
  Future<SendResponse> send(SendInput input, {EnvValues? env}) async {
    final String? fallback = defaultLanguage;
    if (input.language == null && fallback != null) input = input.copyWith(language: fallback);
    verifyPayload(input);
    final Map<String, dynamic> payload = buildSendPayload(input);

    final EnvValues? e = env ?? _env;
    final EncryptedBody enc = await encryptPayload(payload, resolveKeys(e));

    final String what = '${input.type.wire}.${input.channel.wire}.${input.template}';
    try {
      final Map<String, dynamic> res = await _http.post('/sdk/send', enc, e);
      return SendResponse.fromJson(res);
    } on CatzApiException catch (err) {
      // Same message as before; the server's status and `code`
      // (plan_required, minutes_cap_reached, provider_not_allowed, …) are
      // kept on the error.
      throw CatzApiException(err.status, 'Failed to send $what: ${err.message}', err.body,
          code: err.code, cause: err);
    } on UnsupportedError {
      rethrow;
    } catch (err) {
      final String m = err is CatzException ? err.message : err.toString();
      throw CatzException('Failed to send $what: $m', cause: err);
    }
  }
}

/// A ready-made client that reads the `CATZCONNECT_*` values, like the
/// TypeScript SDK's `catzconnect`.
final CatzConnect catzconnect = CatzConnect();
