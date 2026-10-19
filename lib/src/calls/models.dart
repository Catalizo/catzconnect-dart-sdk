// Plain data types shared by the protocol layer and the call client.
//
// Nothing in this file depends on Flutter or WebRTC, so it can be unit tested
// with plain `flutter test` / `dart test`.

/// Default signaling endpoint.
const String kDefaultCallsUrl = 'wss://api.catzconnect.com/rtc/v1/ws';

/// How long the server keeps a participant joined after its signaling socket
/// drops. A `resume` sent within this window keeps the call going.
const Duration kResumeGrace = Duration(seconds: 30);

/// Audio-only or audio+video call.
enum CallMode {
  audio,
  video;

  static CallMode parse(Object? value) =>
      asString(value)?.toLowerCase() == 'video' ? CallMode.video : CallMode.audio;

  String get wire => name;
}

/// Local media kinds that can be muted.
enum MediaKind {
  audio,
  video;

  String get wire => name;
}

/// How media reaches a peer: straight peer-to-peer, or through the relay.
enum ConnectionType {
  direct,
  relay;

  String get wire => name;

  static ConnectionType? parse(Object? value) {
    switch (asString(value)?.toLowerCase()) {
      case 'direct':
        return ConnectionType.direct;
      case 'relay':
        return ConnectionType.relay;
      default:
        return null;
    }
  }
}

/// Call lifecycle as reported by the server in `state` messages.
enum CallStatus {
  ringing,
  active,
  ended,
  missed,
  declined,
  canceled,
  failed,
  unknown;

  static CallStatus parse(Object? value) {
    final String? s = asString(value)?.toLowerCase();
    for (final CallStatus c in CallStatus.values) {
      if (c.name == s) return c;
    }
    // Accept the British spelling too.
    if (s == 'cancelled') return CallStatus.canceled;
    return CallStatus.unknown;
  }

  /// True for statuses after which the call can no longer be joined.
  bool get isFinal =>
      this == CallStatus.ended ||
      this == CallStatus.missed ||
      this == CallStatus.declined ||
      this == CallStatus.canceled ||
      this == CallStatus.failed;
}

/// Coarse quality level derived from rtt / jitter / loss.
enum QualityLevel { good, fair, poor, unknown }

// ---------------------------------------------------------------------------
// Lenient JSON readers (the server is Rust/serde, but be forgiving anyway).
// ---------------------------------------------------------------------------

String? asString(Object? v) {
  if (v == null) return null;
  if (v is String) return v;
  if (v is num || v is bool) return v.toString();
  return null;
}

bool? asBool(Object? v) {
  if (v is bool) return v;
  if (v is num) return v != 0;
  if (v is String) {
    final String s = v.toLowerCase();
    if (s == 'true' || s == '1' || s == 'yes') return true;
    if (s == 'false' || s == '0' || s == 'no') return false;
  }
  return null;
}

double? asDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

int? asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.round();
  if (v is String) {
    final int? i = int.tryParse(v);
    if (i != null) return i;
    final double? d = double.tryParse(v);
    return d?.round();
  }
  return null;
}

Map<String, dynamic>? asMap(Object? v) {
  if (v is Map<String, dynamic>) return v;
  if (v is Map) {
    final Map<String, dynamic> out = <String, dynamic>{};
    v.forEach((Object? key, Object? value) {
      if (key != null) out[key.toString()] = value;
    });
    return out;
  }
  return null;
}

List<Object?> asList(Object? v) {
  if (v is List) return List<Object?>.from(v);
  return const <Object?>[];
}

// ---------------------------------------------------------------------------
// Data classes
// ---------------------------------------------------------------------------

/// One ICE (STUN/TURN) server handed out by the signaling server.
class IceServer {
  const IceServer({required this.urls, this.username, this.credential});

  final List<String> urls;
  final String? username;
  final String? credential;

  factory IceServer.fromJson(Map<String, dynamic> json) {
    final Object? rawUrls = json['urls'] ?? json['url'];
    final List<String> urls = <String>[];
    if (rawUrls is String) {
      urls.add(rawUrls);
    } else {
      for (final Object? u in asList(rawUrls)) {
        final String? s = asString(u);
        if (s != null && s.isNotEmpty) urls.add(s);
      }
    }
    return IceServer(
      urls: urls,
      username: asString(json['username']),
      credential: asString(json['credential']),
    );
  }

  static List<IceServer> listFromJson(Object? value) {
    final List<IceServer> out = <IceServer>[];
    for (final Object? item in asList(value)) {
      final Map<String, dynamic>? m = asMap(item);
      if (m == null) continue;
      final IceServer s = IceServer.fromJson(m);
      if (s.urls.isNotEmpty) out.add(s);
    }
    return out;
  }

  /// Shape expected by `createPeerConnection` / `setConfiguration`.
  Map<String, dynamic> toJson() {
    final Map<String, dynamic> m = <String, dynamic>{'urls': List<String>.from(urls)};
    if (username != null) m['username'] = username;
    if (credential != null) m['credential'] = credential;
    return m;
  }

  /// True when at least one URL is a TURN relay.
  bool get isTurn => urls.any((String u) => u.startsWith('turn:') || u.startsWith('turns:'));
}

/// A user listed on a call.
class CallParticipant {
  const CallParticipant({
    required this.userId,
    this.role,
    this.state,
    this.joinedAt,
    this.leftAt,
    this.seconds,
    this.connection,
  });

  final String userId;

  /// `caller` or `callee`.
  final String? role;

  /// `invited`, `ringing`, `joined`, `left`, `declined` or `missed`.
  final String? state;

  /// When the participant joined (ISO 8601), from `calls.get` on the server.
  final String? joinedAt;

  /// When the participant left (ISO 8601), from `calls.get`.
  final String? leftAt;

  /// Seconds in the call, from `calls.get`.
  final int? seconds;

  /// `direct`, `relay` or `provider`, from `calls.get`.
  final String? connection;

  factory CallParticipant.fromJson(Map<String, dynamic> json) => CallParticipant(
        userId: asString(json['user_id']) ?? asString(json['userId']) ?? '',
        role: asString(json['role']),
        state: asString(json['state']),
        joinedAt: asString(json['joined_at']),
        leftAt: asString(json['left_at']),
        seconds: asInt(json['seconds']),
        connection: asString(json['connection']),
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'user_id': userId,
        if (role != null) 'role': role,
        if (state != null) 'state': state,
        if (joinedAt != null) 'joined_at': joinedAt,
        if (leftAt != null) 'left_at': leftAt,
        if (seconds != null) 'seconds': seconds,
        if (connection != null) 'connection': connection,
      };
}

/// Call description as sent in `incoming` and `joined`.
class CallInfo {
  const CallInfo({
    required this.id,
    required this.mode,
    this.engine,
    this.from,
    this.status,
    this.participants = const <CallParticipant>[],
    this.metadata,
    this.raw = const <String, dynamic>{},
  });

  final String id;
  final CallMode mode;
  final String? engine;

  /// External user id of the caller.
  final String? from;
  final CallStatus? status;
  final List<CallParticipant> participants;
  final Map<String, dynamic>? metadata;

  /// The full JSON object, for fields this SDK does not model.
  final Map<String, dynamic> raw;

  factory CallInfo.fromJson(Map<String, dynamic> json) {
    final List<CallParticipant> parts = <CallParticipant>[];
    for (final Object? p in asList(json['participants'])) {
      final Map<String, dynamic>? m = asMap(p);
      if (m != null) parts.add(CallParticipant.fromJson(m));
    }
    final Object? st = json['status'];
    return CallInfo(
      id: asString(json['id']) ?? asString(json['call_id']) ?? '',
      mode: CallMode.parse(json['mode']),
      engine: asString(json['engine']),
      from: asString(json['from']) ?? asString(json['created_by']),
      status: st == null ? null : CallStatus.parse(st),
      participants: parts,
      metadata: asMap(json['metadata']),
      raw: json,
    );
  }
}

/// Another participant's connection inside a call.
class PeerInfo {
  const PeerInfo({required this.pid, required this.userId, this.epoch});

  /// Participant id (UUID) — unique per participant in a call.
  final String pid;

  /// External user id.
  final String userId;

  /// Join epoch of this participant: the server increments it each time
  /// the participant joins anew (e.g. moves to another device). Null when
  /// unknown (older server, or a session opened by an early offer).
  final int? epoch;

  factory PeerInfo.fromJson(Map<String, dynamic> json) {
    final Object? e = json['epoch'];
    return PeerInfo(
      pid: asString(json['pid']) ?? '',
      userId: asString(json['user_id']) ?? asString(json['userId']) ?? '',
      epoch: e is num ? e.toInt() : null,
    );
  }

  /// This peer, keeping [fallback]'s epoch when this one has none.
  PeerInfo withEpochFrom(PeerInfo fallback) =>
      epoch != null ? this : PeerInfo(pid: pid, userId: userId, epoch: fallback.epoch);

  @override
  String toString() => 'PeerInfo($pid, $userId)';
}

/// Hand-off data when the call runs on a third-party provider (engine is not
/// `catz`). Pass it to that provider's own SDK.
class ProviderInfo {
  const ProviderInfo({
    required this.callId,
    required this.name,
    this.room,
    this.token,
    this.appId,
    this.url,
    this.extra,
  });

  final String callId;

  /// Provider id, e.g. `agora`, `twilio_video`, `livekit`.
  final String name;
  final String? room;
  final String? token;
  final String? appId;
  final String? url;
  final Map<String, dynamic>? extra;

  factory ProviderInfo.fromJson(String callId, Map<String, dynamic> json) => ProviderInfo(
        callId: callId,
        name: asString(json['name']) ?? '',
        room: asString(json['room']),
        token: asString(json['token']),
        appId: asString(json['app_id']),
        url: asString(json['url']),
        extra: asMap(json['extra']),
      );
}

/// A call that is ringing for this user, from the signaling socket or from a
/// push notification.
class IncomingCall {
  const IncomingCall({
    required this.callId,
    required this.from,
    required this.mode,
    this.engine,
    this.call,
    this.fromPush = false,
  });

  final String callId;

  /// External user id of the caller.
  final String from;
  final CallMode mode;
  final String? engine;

  /// Full call description (only for calls received over the socket).
  final CallInfo? call;

  /// True when built from a push payload with `CatzCalls.incomingFromPush`.
  final bool fromPush;

  /// Metadata the backend attached to `calls.create` (socket only).
  Map<String, dynamic>? get metadata => call?.metadata;

  factory IncomingCall.fromCall(CallInfo call) => IncomingCall(
        callId: call.id,
        from: call.from ?? '',
        mode: call.mode,
        engine: call.engine,
        call: call,
      );

  @override
  String toString() => 'IncomingCall($callId from $from, ${mode.name}, engine $engine)';
}

/// `state` message: call status change.
class CallStateEvent {
  const CallStateEvent({required this.callId, required this.status, this.reason});

  final String callId;
  final CallStatus status;
  final String? reason;

  @override
  String toString() => 'CallStateEvent($callId, ${status.name}, $reason)';
}

class PeerJoinedEvent {
  const PeerJoinedEvent({required this.callId, required this.peer});

  final String callId;
  final PeerInfo peer;
}

class PeerLeftEvent {
  const PeerLeftEvent({required this.callId, required this.peer, this.reason});

  final String callId;
  final PeerInfo peer;
  final String? reason;
}

/// Media path to one peer changed (direct ↔ relay).
class ConnectionEvent {
  const ConnectionEvent({required this.callId, required this.peer, required this.type});

  final String callId;
  final PeerInfo peer;
  final ConnectionType type;
}

/// Link quality to one peer, sampled every 10 seconds.
class CallQuality {
  const CallQuality({
    required this.callId,
    required this.peer,
    this.connection,
    this.rttMs,
    this.jitterMs,
    this.lossPct,
    this.bitrateKbps,
    this.level = QualityLevel.unknown,
  });

  final String callId;
  final PeerInfo peer;
  final ConnectionType? connection;
  final double? rttMs;
  final double? jitterMs;
  final double? lossPct;
  final double? bitrateKbps;
  final QualityLevel level;

  @override
  String toString() => 'CallQuality(${peer.pid}, ${connection?.name}, rtt=$rttMs, '
      'jitter=$jitterMs, loss=$lossPct, kbps=$bitrateKbps, ${level.name})';
}

/// What is being restored: the signaling socket, or the media path to one
/// peer (ICE restart).
enum ReconnectScope { signaling, peer }

/// Signaling or a peer path dropped; the client is restoring it. The call is
/// not over.
class ReconnectingEvent {
  const ReconnectingEvent({
    required this.scope,
    required this.attempt,
    this.delay,
    this.callId,
    this.pid,
  });

  final ReconnectScope scope;

  /// Counts from 1.
  final int attempt;

  /// Wait before the next signaling attempt (signaling scope only).
  final Duration? delay;
  final String? callId;

  /// The peer being ICE-restarted (peer scope only).
  final String? pid;

  @override
  String toString() => 'ReconnectingEvent(${scope.name}, attempt $attempt, call $callId, pid $pid)';
}

/// Signaling is back (and the call was resumed or rejoined), or a peer's
/// media path recovered.
class ReconnectedEvent {
  const ReconnectedEvent({required this.scope, this.callId, this.pid});

  final ReconnectScope scope;
  final String? callId;
  final String? pid;

  @override
  String toString() => 'ReconnectedEvent(${scope.name}, call $callId, pid $pid)';
}

/// Error reported by the server (`error` message) or raised locally.
class CallError implements Exception {
  const CallError(this.code, this.message, {this.callId});

  /// Machine-readable code, e.g. `plan_required`, `minutes_cap_reached`,
  /// `connect_failed`, `media_error`, `not_supported`.
  final String code;
  final String message;
  final String? callId;

  @override
  String toString() => 'CallError($code): $message';
}
