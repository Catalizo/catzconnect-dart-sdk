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
    return CatzApiException(status, message, body, code: code);
  }

  @override
  int get status => super.status!;

  @override
  String get body => super.body!;
}

/// The name the TypeScript SDK uses.
typedef CatzApiError = CatzApiException;

/// Throws a [CatzValidationException]. Used by the validators so their
/// messages match the TypeScript SDK word for word.
Never fail(String message) => throw CatzValidationException(message);
