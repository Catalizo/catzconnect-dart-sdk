// Port of sdk/typescript/src/core/webhook.ts. Pure Dart (no libsodium), so
// these are synchronous and work everywhere.

import 'dart:convert';
import 'dart:typed_data';

import 'sha256.dart';

final RegExp _digits = RegExp(r'^\d+$');
final RegExp _hex64 = RegExp(r'^[0-9a-fA-F]{64}$');

/// Verify a webhook's `Catz-Signature` header.
///
/// The header is `t=<unix seconds>,v1=<hex HMAC-SHA256>`; the MAC is taken
/// over `"<t>.<raw body>"` with the webhook's signing secret (`whsec_…`) as
/// the key. Pass [rawBody] exactly as received — before any JSON parsing —
/// as a `String` (UTF-8 encoded here) or the bytes (`List<int>`), and the
/// secret as shown in the panel.
///
/// Returns false for a missing or malformed header, a timestamp further than
/// [toleranceSeconds] (default 300; 0 or less skips the check) from
/// [nowSeconds] (default: now), or a signature that does not match. The
/// comparison is constant-time.
bool verifyWebhookSignature(
  Object rawBody,
  String? header,
  String secret, {
  int toleranceSeconds = 300,
  int? nowSeconds,
}) {
  if (header == null || header.isEmpty || secret.isEmpty) return false;

  String? t;
  final List<String> v1 = <String>[];
  for (final String part in header.split(',')) {
    final int i = part.indexOf('=');
    if (i <= 0) continue;
    final String k = part.substring(0, i).trim();
    final String v = part.substring(i + 1).trim();
    if (k == 't') {
      t = v;
    } else if (k == 'v1') {
      v1.add(v);
    }
  }

  if (t == null || t.isEmpty || !_digits.hasMatch(t) || v1.isEmpty) return false;
  final int now = nowSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final int? ts = int.tryParse(t);
  if (toleranceSeconds > 0 && (ts == null || (now - ts).abs() > toleranceSeconds)) return false;

  final List<int> body;
  if (rawBody is String) {
    body = utf8.encode(rawBody);
  } else if (rawBody is List<int>) {
    body = rawBody;
  } else {
    throw ArgumentError.value(rawBody, 'rawBody', 'must be a String or List<int>');
  }
  final List<int> prefix = utf8.encode('$t.');
  final Uint8List signed = Uint8List(prefix.length + body.length)
    ..setRange(0, prefix.length, prefix)
    ..setRange(prefix.length, prefix.length + body.length, body);
  final Uint8List expected = hmacSha256(utf8.encode(secret), signed);

  bool match = false;
  for (final String sig in v1) {
    if (!_hex64.hasMatch(sig)) continue;
    final Uint8List? got = fromHex(sig);
    if (got != null && constantTimeEquals(expected, got)) match = true;
  }
  return match;
}

/// The `user_hash` for `POST /push/register`: hex HMAC-SHA256 of the
/// [externalUserId], keyed with the push project's identity secret
/// (`pis_…`, Push → Projects in the panel).
///
/// Compute it on your SERVER and hand it to your app with the user id. The
/// identity secret must never ship inside the app — anyone holding it could
/// register their device as any of your users. Without a valid hash, the
/// device is registered with no user.
String computeUserHash(String externalUserId, String identitySecret) {
  if (identitySecret.isEmpty) {
    throw ArgumentError('computeUserHash: identity secret is required');
  }
  return toHex(hmacSha256(utf8.encode(identitySecret), utf8.encode(externalUserId)));
}

/// Every event a webhook can subscribe to.
const List<String> kWebhookEvents = <String>[
  'email.sent', 'email.failed', 'email.bounced', 'email.opened', 'email.clicked', 'email.received', //
  'whatsapp.status', 'whatsapp.inbound', 'whatsapp.read', //
  'push.sent', 'push.failed', //
  'sms.sent', 'sms.delivered', 'sms.failed', 'sms.unknown', //
  'call.ringing', 'call.started', 'call.ended', 'call.missed', 'call.declined', 'call.canceled', 'call.failed', //
  'participant.joined', 'participant.left', //
  'voice.answered', 'voice.completed', 'voice.failed', 'voice.unknown', //
  'email.complained', 'email.unsubscribed', 'push.opened', 'sms.inbound', 'sms.opt_out', 'whatsapp.opt_out',
];

/// A verified webhook delivery. [test] is true for events of test (sandbox) keys.
class WebhookEvent {
  const WebhookEvent({
    required this.id,
    required this.type,
    required this.createdAt,
    required this.organizationId,
    required this.test,
    required this.data,
  });

  final String id;
  final String type;
  final String createdAt;
  final String organizationId;
  final bool test;
  final Map<String, dynamic> data;
}

/// Verify the `Catz-Signature` header and decode the event. Throws a
/// [FormatException] when the signature does not match (or is too old) or
/// the body is not an event.
WebhookEvent parseWebhookEvent(
  Object rawBody,
  String? header,
  String secret, {
  int toleranceSeconds = 300,
  int? nowSeconds,
}) {
  if (!verifyWebhookSignature(rawBody, header, secret, toleranceSeconds: toleranceSeconds, nowSeconds: nowSeconds)) {
    throw const FormatException('Invalid webhook signature');
  }
  final String text = rawBody is String ? rawBody : utf8.decode(rawBody as List<int>);
  final Object? j = jsonDecode(text);
  if (j is! Map || j['id'] is! String || j['type'] is! String) {
    throw const FormatException('The webhook body is not a Catz Connect event');
  }
  final Object? d = j['data'];
  final Map<String, dynamic> data = d is Map ? Map<String, dynamic>.from(d) : <String, dynamic>{};
  return WebhookEvent(
    id: j['id'] as String,
    type: j['type'] as String,
    createdAt: j['created_at']?.toString() ?? '',
    organizationId: j['organization_id']?.toString() ?? '',
    test: j['test'] == true || data['test'] == true,
    data: data,
  );
}
