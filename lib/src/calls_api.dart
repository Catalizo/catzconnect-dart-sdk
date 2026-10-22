// Server-side Voice & Video calls: create a call, mint a short-lived user
// token for the app, read a call, end it. Port of sdk/typescript/src/calls.ts.
//
// Every request uses the same API key, encryption and headers as send().
// The app side is CatzCallClient.

import 'dart:convert';

import 'calls/models.dart';
import 'core/crypto.dart';
import 'core/env.dart';
import 'core/errors.dart';
import 'core/http.dart';
import 'types.dart';
import 'utils/validators.dart';

/// Most callees per call (the caller is the 50th participant).
const int kCallMaxCallees = 49;

/// Longest external user id.
const int kCallUserIdMax = 128;

/// Largest `metadata`, serialised as JSON (UTF-8 bytes).
const int kCallMetadataMaxBytes = 4096;

/// Shortest user-token lifetime, in seconds.
const int kCallTokenTtlMin = 60;

/// Longest user-token lifetime, in seconds.
const int kCallTokenTtlMax = 86400;

/// What `calls.create` takes.
class CreateCallInput {
  const CreateCallInput({
    required this.mode,
    required this.from,
    required this.to,
    this.engine,
    this.ring,
    this.metadata,
    this.maxParticipants,
  });

  /// [CallMode.audio] or [CallMode.video].
  final CallMode mode;

  /// The caller's external user id (your user id, up to 128 characters).
  final String from;

  /// The callees' external user ids: 1–49, unique, not including [from].
  final List<String> to;

  /// `"auto"` (default: the org's setting), `"catz"` (our peer-to-peer
  /// engine), or a configured provider's id or label (it must be in the
  /// key's scope).
  final String? engine;

  /// Ring the callees (WebSocket + push). Default true on the server.
  final bool? ring;

  /// Your own JSON object, up to 4 KB; delivered with `incoming`.
  final Map<String, Object?>? metadata;

  /// Participant cap for this call (caller included), 2–50. Sent as
  /// `max_participants`.
  final int? maxParticipants;
}

/// The configured provider of a call whose engine is not `catz`.
class CallProvider {
  const CallProvider({required this.id, this.label, required this.name});

  /// Provider row id.
  final String id;

  /// Its label in the panel.
  final String? label;

  /// Registry name: `agora`, `livekit`, …
  final String name;

  factory CallProvider.fromJson(Map<String, dynamic> json) => CallProvider(
        id: asString(json['id']) ?? '',
        label: asString(json['label']),
        name: asString(json['name']) ?? '',
      );
}

/// A call as the server API returns it.
class Call {
  const Call({
    required this.id,
    required this.engine,
    this.provider,
    required this.mode,
    required this.status,
    required this.room,
    required this.participants,
    required this.createdAt,
    this.startedAt,
    this.endedAt,
    this.durationSecs,
    this.billedMinutes,
    this.endReason,
    this.metadata,
    this.raw = const <String, dynamic>{},
  });

  final String id;

  /// `"catz"` or a provider id.
  final String engine;

  /// The configured provider when [engine] is not `catz`.
  final CallProvider? provider;
  final CallMode mode;
  final CallStatus status;
  final String room;
  final List<CallParticipant> participants;

  /// ISO 8601.
  final String createdAt;
  final String? startedAt;
  final String? endedAt;
  final int? durationSecs;
  final int? billedMinutes;
  final String? endReason;
  final Map<String, dynamic>? metadata;

  /// The call object as received, for fields this SDK does not model.
  final Map<String, dynamic> raw;

  factory Call.fromJson(Map<String, dynamic> json) {
    final List<CallParticipant> parts = <CallParticipant>[];
    for (final Object? p in asList(json['participants'])) {
      final Map<String, dynamic>? m = asMap(p);
      if (m != null) parts.add(CallParticipant.fromJson(m));
    }
    final Map<String, dynamic>? provider = asMap(json['provider']);
    return Call(
      id: asString(json['id']) ?? '',
      engine: asString(json['engine']) ?? '',
      provider: provider == null ? null : CallProvider.fromJson(provider),
      mode: CallMode.parse(json['mode']),
      status: CallStatus.parse(json['status']),
      room: asString(json['room']) ?? '',
      participants: parts,
      createdAt: asString(json['created_at']) ?? '',
      startedAt: asString(json['started_at']),
      endedAt: asString(json['ended_at']),
      durationSecs: asInt(json['duration_secs']),
      billedMinutes: asInt(json['billed_minutes']),
      endReason: asString(json['end_reason']),
      metadata: asMap(json['metadata']),
      raw: json,
    );
  }
}

/// A user token from `calls.token`.
class CallToken {
  const CallToken({required this.token, required this.expiresAt, required this.wsUrl});

  /// `ct1.…` — give it to the app; it never contains your API key.
  final String token;

  /// As the server sent it: an ISO 8601 string or unix seconds (`''` when
  /// absent).
  final Object expiresAt;

  /// The signaling WebSocket URL to pass to `CatzCallClient(url: …)`.
  final String wsUrl;

  /// [expiresAt] as a time, when it can be read.
  DateTime? get expiresAtTime {
    final Object e = expiresAt;
    if (e is int) return DateTime.fromMillisecondsSinceEpoch(e * 1000, isUtc: true);
    if (e is num) return DateTime.fromMillisecondsSinceEpoch((e * 1000).round(), isUtc: true);
    if (e is String) return DateTime.tryParse(e);
    return null;
  }

  Map<String, Object> toJson() => <String, Object>{'token': token, 'expires_at': expiresAt, 'ws_url': wsUrl};
}

/// The answer of `calls.end`.
class EndCallResult {
  const EndCallResult({required this.success, required this.message});

  final bool success;
  final String message;
}

/// Throws unless [id] is a usable external user id: non-empty, ≤ 128
/// characters, no control characters. Returns it unchanged.
String validateCallUserId(String? id, [String field = 'user id']) {
  if (id == null || id.trim().isEmpty) {
    fail('Missing $field');
  }
  if (codePointLength(id) > kCallUserIdMax) {
    fail('$field must be at most $kCallUserIdMax characters');
  }
  if (hasControlChars(id)) {
    fail('$field contains control characters');
  }
  return id;
}

String _validateCallId(String? id) {
  if (id == null || id.trim().isEmpty) {
    fail('Missing call id');
  }
  if (id.length > 128 || hasControlChars(id)) {
    fail('Invalid call id');
  }
  return id.trim();
}

/// The JSON body (before encryption) `calls.create` posts. Validates first,
/// as the server does.
Map<String, dynamic> buildCreateCallPayload(CreateCallInput input) {
  final String from = validateCallUserId(input.from, "'from'");
  if (input.to.isEmpty) {
    fail("'to' must list at least one user id");
  }
  if (input.to.length > kCallMaxCallees) {
    fail("'to' can list at most $kCallMaxCallees user ids");
  }
  final Set<String> seen = <String>{};
  for (final String u in input.to) {
    validateCallUserId(u, "'to' entry");
    if (u == from) {
      fail("'to' must not include the caller ('from')");
    }
    if (seen.contains(u)) {
      fail("'to' lists '$u' twice");
    }
    seen.add(u);
  }

  final Map<String, dynamic> out = <String, dynamic>{
    'mode': input.mode.wire,
    'from': from,
    'to': List<String>.from(input.to),
  };

  final String? engine = input.engine;
  if (engine != null) {
    if (engine.trim().isEmpty) {
      fail("'engine' must be \"auto\", \"catz\" or a provider id or label");
    }
    out['engine'] = engine.trim();
  }
  final bool? ring = input.ring;
  if (ring != null) {
    out['ring'] = ring;
  }
  final Map<String, Object?>? metadata = input.metadata;
  if (metadata != null) {
    String json;
    try {
      json = jsonEncode(metadata);
    } on JsonUnsupportedObjectError {
      fail("'metadata' must be serialisable as JSON");
    }
    if (utf8.encode(json).length > kCallMetadataMaxBytes) {
      fail("'metadata' must be at most 4 KB as JSON");
    }
    out['metadata'] = metadata;
  }
  final int? n = input.maxParticipants;
  if (n != null) {
    if (n < 2 || n > kCallMaxCallees + 1) {
      fail("'maxParticipants' must be a whole number from 2 to ${kCallMaxCallees + 1}");
    }
    if (input.to.length + 1 > n) {
      fail("${input.to.length + 1} participants do not fit 'maxParticipants' $n");
    }
    out['max_participants'] = n;
  }
  return out;
}

/// The JSON body `calls.token` posts.
Map<String, dynamic> buildCallTokenPayload(String userId, [int? ttlSeconds]) {
  final Map<String, dynamic> out = <String, dynamic>{'user_id': validateCallUserId(userId, "'userId'")};
  if (ttlSeconds != null) {
    if (ttlSeconds < kCallTokenTtlMin || ttlSeconds > kCallTokenTtlMax) {
      fail("'ttlSeconds' must be a whole number from $kCallTokenTtlMin to $kCallTokenTtlMax");
    }
    out['ttl_seconds'] = ttlSeconds;
  }
  return out;
}

/// Fields may arrive at the top level (`{success, call}`) or under `data`.
Object? _field(Map<String, dynamic> res, String name) {
  if (res[name] != null) return res[name];
  final Object? data = res['data'];
  if (data is Map && data[name] != null) return data[name];
  return null;
}

Call _needCall(Map<String, dynamic> res) {
  final Map<String, dynamic>? call = asMap(_field(res, 'call'));
  if (call == null || call['id'] is! String) {
    final String j = jsonEncode(res);
    throw CatzException('Unexpected response: no call in ${j.length > 200 ? j.substring(0, 200) : j}');
  }
  return Call.fromJson(call);
}

/// `catzconnect.calls` — Voice & Video calls from your backend.
class CallsApi {
  CallsApi(this._http, [this._env]);

  final CatzHttp _http;
  final EnvValues? _env;

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body, EnvValues? env) async {
    final EnvValues? e = env ?? _env;
    final ResolvedKeys keys = resolveKeys(e);
    final EncryptedBody enc = await encryptPayload(body, keys);
    final Map<String, dynamic> res = await _http.request(path, enc, e, rebuild: () => encryptPayload(body, keys));
    return openResponse(res, keys);
  }

  /// Creates a call and (unless `ring: false`) rings the callees. Then call
  /// `calls.token(from)` and hand the token to the caller's app, which joins
  /// with `client.join(call.id)`.
  Future<Call> create(CreateCallInput input, {EnvValues? env}) async {
    final Map<String, dynamic> res = await _post('/sdk/calls/create', buildCreateCallPayload(input), env);
    return _needCall(res);
  }

  /// Mints a user token for the app's [CatzCallClient]. [ttlSeconds]
  /// 60–86400, default 3600 on the server.
  Future<CallToken> token(String userId, {int? ttlSeconds, EnvValues? env}) async {
    final Map<String, dynamic> res = await _post('/sdk/calls/token', buildCallTokenPayload(userId, ttlSeconds), env);
    final Object? token = _field(res, 'token');
    if (token is! String || token.isEmpty) {
      throw CatzException('Unexpected response: no token');
    }
    final Object? expires = _field(res, 'expires_at');
    final Object? ws = _field(res, 'ws_url');
    return CallToken(
      token: token,
      expiresAt: (expires is String || expires is num) ? expires! : '',
      wsUrl: ws is String ? ws : '',
    );
  }

  /// Reads a call with its participants, duration, billed minutes and end
  /// reason.
  Future<Call> get(String callId, {EnvValues? env}) async {
    final Map<String, dynamic> res =
        await _post('/sdk/calls/get', <String, dynamic>{'call_id': _validateCallId(callId)}, env);
    return _needCall(res);
  }

  /// Ends a call for everyone (ringing → canceled, active → ended).
  Future<EndCallResult> end(String callId, {String? reason, EnvValues? env}) async {
    final Map<String, dynamic> body = <String, dynamic>{'call_id': _validateCallId(callId)};
    if (reason != null && reason.trim().isNotEmpty) body['reason'] = reason.trim();
    final Map<String, dynamic> res = await _post('/sdk/calls/end', body, env);
    final Object? message = res['message'];
    return EndCallResult(success: res['success'] != false, message: message is String ? message : '');
  }
}
