// The server SDK client: send() and calls. Port of sdk/typescript/src/index.ts.

import 'app/app_session.dart';
import 'app/app_session_api.dart';
import 'app/attest_platform.dart';
import 'calls_api.dart';
import 'core/crypto.dart';
import 'core/env.dart';
import 'core/errors.dart';
import 'core/http.dart';
import 'core/payload.dart';
import 'core/sodium/sodium_backend.dart';
import 'core/transport.dart';
import 'devapi.dart';
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
/// The base URL must be `https://`; plain `http://` is accepted only for
/// localhost / 127.0.0.1 / ::1 / 10.0.2.2, or with `allowInsecureHttp: true`
/// (or `CATZCONNECT_ALLOW_INSECURE_HTTP=1`). Otherwise requests throw a
/// [CatzException] before anything is sent.
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
    bool allowInsecureHttp = false,
  })  : _env = env,
        defaultLanguage = defaultLanguage == null ? null : normaliseLanguage(defaultLanguage),
        _http = CatzHttp(baseUrl: baseUrl, transport: transport, timeout: timeout, allowInsecureHttp: allowInsecureHttp) {
    calls = CallsApi(_http, env);
    messages = MessagesApi(_http, env);
    otp = OtpApi(_http, env);
    manage = ManageApi(_http, env);
    pushDevices = PushDevicesApi(_http);
    push = PushApi(_http, env);
  }

  /// A client for an **app key**: a key made for mobile apps that only works
  /// together with a short-lived app session, which the server issues after
  /// checking a Google Play Integrity verdict (Android) or an Apple App
  /// Attest attestation / assertion (iOS). An app key copied out of the app
  /// is useless elsewhere. Read the README's "App keys" section first.
  ///
  /// Everything happens on the first request (or call `appSession!.ensure()`
  /// at start-up): challenge → attestation →
  /// session, cached in memory, renewed shortly before it expires, and sent
  /// as `X-Catz-App-Session` on every request; a request refused with
  /// `app_session_expired` / `app_session_invalid` is retried once with a
  /// new session.
  ///
  /// - [appKey], [privateKey], [serverPublicKey]: from the panel (API keys →
  ///   your app key), as for a server key.
  /// - [playCloudProjectNumber]: Android, the Google Cloud project number
  ///   linked in Play Console → App integrity. Optional: when null, the one
  ///   configured on the app key is used.
  /// - [debugToken]: a debug token from the app key (when the key allows
  ///   debug) — used **instead of** attestation, for emulators, the iOS
  ///   Simulator and builds not installed from Google Play. Pass it in debug
  ///   builds only, e.g. `debugToken: kReleaseMode ? null : const
  ///   String.fromEnvironment('CATZ_DEBUG_TOKEN')`. In a release build it
  ///   is ignored (with a printed warning) and the app attests.
  /// - [attestPlatform]: the native side; defaults to the plugin's method
  ///   channel. Tests pass a fake.
  ///
  /// Failures to attest throw a [CatzAttestationException] with a reason
  /// code; limits throw a [CatzRateLimitException]. App keys can send the
  /// templates the key allows (by default the built-in `Otp`); `calls.*`
  /// are refused with `not_allowed_for_app_keys`.
  factory CatzConnect.app({
    required String appKey,
    required String privateKey,
    required String serverPublicKey,
    String? playCloudProjectNumber,
    String? debugToken,
    String? baseUrl,
    CatzTransport? transport,
    Duration timeout = const Duration(seconds: 30),
    String? defaultLanguage,
    CatzAttestPlatform? attestPlatform,
    DateTime Function()? clock,
    bool allowInsecureHttp = false,
  }) {
    final EnvValues env = EnvValues(apiKey: appKey, privateKey: privateKey, serverPublicKey: serverPublicKey);
    final CatzConnect c = CatzConnect(
      env: env,
      baseUrl: baseUrl,
      transport: transport,
      timeout: timeout,
      defaultLanguage: defaultLanguage,
      allowInsecureHttp: allowInsecureHttp,
    );
    final CatzAppSessionManager manager = CatzAppSessionManager(
      api: HttpAppSessionApi(c._http, env, clock: clock),
      platform: attestPlatform ?? MethodChannelAttestPlatform(),
      appKey: appKey,
      cloudProjectNumber: playCloudProjectNumber,
      debugToken: debugToken,
      clock: clock,
    );
    c._http.appSession = manager;
    c._appSession = manager;
    return c;
  }

  final EnvValues? _env;
  final CatzHttp _http;
  CatzAppSessionManager? _appSession;

  /// App keys ([CatzConnect.app]): the session manager — `ensure()` to
  /// attest ahead of the first send, `current` for the session's expiry,
  /// debug flag and limits, `clear()` / `resetDevice()`. Null for server
  /// keys.
  CatzAppSessionManager? get appSession => _appSession;

  /// Whether this client uses an app key.
  bool get isAppKey => _appSession != null;

  /// The `language` (normalised, e.g. `'de'`) used by every [send] whose
  /// [SendInput.language] is `null`. Set with the `defaultLanguage`
  /// constructor argument (en, de, ja, ar, hi or a BCP-47 tag such as
  /// `'de-DE'`; anything else throws a [CatzValidationException]).
  final String? defaultLanguage;

  /// Voice & Video calls: `create`, `token`, `get`, `end`.
  late final CallsApi calls;

  /// Status and event timeline of sent messages: `get`, `list`.
  late final MessagesApi messages;

  /// Hosted one-time codes: `start`, `verify`.
  late final OtpApi otp;

  /// Management API (a server key with the management scope): templates,
  /// webhooks, suppressions, API keys. Keep it on your server.
  late final ManageApi manage;

  /// Push device registry with the project's publishable key (no API key):
  /// `register`, `unregister`, `opened`.
  late final PushDevicesApi pushDevices;

  /// Push broadcasts / scheduled pushes and topic subscriptions from your
  /// server (server key): `broadcast`, `cancel`, `subscribe`, `unsubscribe`,
  /// `topics`.
  late final PushApi push;

  /// Loads libsodium (package:sodium) ahead of the first request, so a missing
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
    final ResolvedKeys keys = resolveKeys(e);
    final EncryptedBody enc = await encryptPayload(payload, keys);

    final String what = '${input.type.wire}.${input.channel.wire}.${input.template}';
    try {
      final Object? idem = payload['idempotency_key'];
      final Map<String, dynamic> res = await _http.post('/sdk/send', enc, e,
          rebuild: () => encryptPayload(payload, keys),
          extraHeaders: idem is String ? <String, String>{'Idempotency-Key': idem} : null);
      return SendResponse.fromJson(res);
    } on CatzAttestationException {
      // App keys: no session could be obtained; the reason code says why.
      rethrow;
    } on CatzRateLimitException catch (err) {
      throw CatzRateLimitException(err.status, 'Failed to send $what: ${err.message}', err.body,
          code: err.code, cause: err);
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
