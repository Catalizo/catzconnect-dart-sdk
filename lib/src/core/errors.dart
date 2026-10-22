import 'dart:convert';

/// Base class of every exception the server SDK throws.
///
/// [status], [code] and [body] are set when the server answered (see
/// [CatzApiException]); [cause] is the underlying error, when there is one.
class CatzException implements Exception {
  CatzException(this.message, {this.status, this.code, this.body, this.cause});

  /// The sentence to show or log.
  final String message;

  /// The HTTP status, when the server answered.
  final int? status;

  /// The server's machine-readable code, when it sent one: `plan_required`,
  /// `minutes_cap_reached`, `engine_unavailable`, `too_many_participants`,
  /// `provider_not_allowed`, …
  final String? code;

  /// The response body as received, when the server answered.
  final String? body;

  /// The underlying error, when there is one.
  final Object? cause;

  /// The JSON refusal when the body was JSON (`{success, message, code, …}`),
  /// with extra fields such as `attempts_remaining` (otp_invalid) or
  /// `retry_after` (otp_resend_cooldown).
  Map<String, dynamic>? get details {
    final String? b = body;
    if (b == null) return null;
    try {
      final Object? j = jsonDecode(b);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => message;
}

/// The input was refused before anything was encrypted or sent. The message
/// is the same sentence the TypeScript SDK throws.
class CatzValidationException extends CatzException {
  CatzValidationException(super.message);
}

/// A refusal from the API: the HTTP status, the server's sentence, and its
/// `code` when it sent one.
///
/// The TypeScript SDK calls this `CatzApiError`; [CatzApiError] is an alias.
class CatzApiException extends CatzException {
  CatzApiException(int status, super.message, String body, {super.code, super.cause})
      : super(status: status, body: body);

  /// Builds the error from a response body, reading `message` and `code` when
  /// it is JSON. Without a usable `message` it is `HTTP <status>: <body>`.
  factory CatzApiException.from(int status, String body) {
    String message = 'HTTP $status: $body';
    String? code;
    try {
      final Object? j = jsonDecode(body);
      if (j is Map) {
        final Object? m = j['message'];
        final Object? c = j['code'];
        if (m is String && m.isNotEmpty) message = m;
        if (c is String && c.isNotEmpty) code = c;
      }
    } on FormatException {
      // not JSON: keep the raw text
    }
    if (status == 429 || code == 'rate_limited') {
      return CatzRateLimitException(status, message, body, code: code);
    }
    return CatzApiException(status, message, body, code: code);
  }

  @override
  int get status => super.status!;

  @override
  String get body => super.body!;
}

/// The name the TypeScript SDK uses.
typedef CatzApiError = CatzApiException;

/// HTTP 429 / `rate_limited`: a limit was reached. Wait [retryAfter] before
/// trying again. With an app key, [limit] says which one (`device`,
/// `recipient` or `key`).
class CatzRateLimitException extends CatzApiException {
  CatzRateLimitException(super.status, super.message, super.body, {super.code, super.cause});

  Map<String, dynamic>? get _json {
    try {
      final Object? j = jsonDecode(body);
      return j is Map ? Map<String, dynamic>.from(j) : null;
    } on FormatException {
      return null;
    }
  }

  /// `retry_after` from the body (seconds), when the server sent it.
  Duration? get retryAfter {
    final Object? v = _json?['retry_after'];
    if (v is num && v >= 0) return Duration(milliseconds: (v * 1000).round());
    if (v is String) {
      final num? n = num.tryParse(v.trim());
      if (n != null && n >= 0) return Duration(milliseconds: (n * 1000).round());
    }
    return null;
  }

  /// App keys: which limit was reached — `device`, `recipient` or `key`.
  String? get limit {
    final Object? v = _json?['limit'];
    return v is String && v.isNotEmpty ? v : null;
  }
}

/// Where a [CatzAttestationException] came from.
enum CatzAttestationSource {
  /// The phone: Play Integrity, App Attest, the plugin, or the SDK's own
  /// checks (for example a simulator without a debug token).
  device,

  /// The Catz Connect server refused the attestation (`attestation_failed`
  /// with a reason code).
  server,
}

/// App keys: the app could not prove it is the genuine app on a genuine
/// device, so no app session was issued and nothing was sent.
///
/// [reason] is a stable, non-sensitive code:
///
/// - From the server (`attestation_failed`, [source] = server):
///   `wrong_package`, `wrong_certificate`, `not_play_recognized`,
///   `device_integrity`, `nonce_mismatch`, `expired`, `bad_signature`,
///   `counter`, `unknown_key`, `play_api_error`, `challenge_invalid`,
///   `bad_format`, `not_configured`, `wrong_environment`, `key_exists`,
///   `debug_not_allowed`, `bad_debug_token`; and `platform_not_configured`
///   when the key has no settings for this platform.
/// - From the device ([source] = device): `unsupported_platform` (not
///   Android/iOS, or the plugin is not registered),
///   `simulator_requires_debug_token`, `emulator_requires_debug_token`,
///   `app_attest_unsupported`, `timeout`, `integrity_<code>` (a Play
///   Integrity `IntegrityErrorCode`, lower-case, e.g.
///   `integrity_network_error`, `integrity_play_store_not_found`) and
///   `app_attest_<code>` (a `DCError`, e.g. `app_attest_invalid_key`,
///   `app_attest_server_unavailable`).
///
/// [retryable] is true for transient failures (network, Google/Apple
/// servers busy) — retry later with backoff; the others need a change to
/// the device, the app build or the key's settings.
class CatzAttestationException extends CatzException {
  CatzAttestationException(
    this.reason,
    super.message, {
    this.source = CatzAttestationSource.device,
    this.platform,
    this.nativeCode,
    super.status,
    super.body,
    super.cause,
    String? serverCode,
  }) : super(code: serverCode ?? (source == CatzAttestationSource.server ? 'attestation_failed' : reason));

  /// The reason code (see the class documentation).
  final String reason;

  /// Device or server.
  final CatzAttestationSource source;

  /// `android` or `ios`, when known.
  final String? platform;

  /// The native error number, when there is one (Play Integrity's
  /// `IntegrityErrorCode`, Apple's `DCError.Code` raw value).
  final int? nativeCode;

  static const Set<String> _retryable = <String>{
    'timeout',
    'play_api_error',
    'challenge_invalid',
    'expired',
    'integrity_network_error',
    'integrity_client_transient_error',
    'integrity_google_server_unavailable',
    'integrity_internal_error',
    'integrity_too_many_requests',
    'integrity_cannot_bind_to_service',
    'app_attest_server_unavailable',
    'app_attest_unknown_system_failure',
  };

  /// Whether trying again later may succeed.
  bool get retryable => _retryable.contains(reason);
}

/// Throws a [CatzValidationException]. Used by the validators so their
/// messages match the TypeScript SDK word for word.
Never fail(String message) => throw CatzValidationException(message);
