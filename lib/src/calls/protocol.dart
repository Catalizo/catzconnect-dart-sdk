// Wire protocol of the Catz Connect signaling WebSocket
// (`GET /rtc/v1/ws?token=<user token>`). JSON text frames `{ "t": type, ... }`.
//
// Pure Dart: no Flutter / WebRTC imports, so it is unit-testable.

import 'dart:convert';

import 'models.dart';

/// Maximum frame size accepted by the server.
const int kMaxFrameBytes = 64 * 1024;

// ---------------------------------------------------------------------------
// Server → client
// ---------------------------------------------------------------------------

/// A decoded server frame. Use a `switch` over the subclasses.
sealed class ServerMessage {
  const ServerMessage(this.raw);

  /// The decoded JSON object.
  final Map<String, dynamic> raw;

  String get type => asString(raw['t']) ?? '';

  /// Decodes one text frame. Throws [FormatException] for anything that is
  /// not a JSON object with a string `t` field.
  static ServerMessage decode(String text) {
    final Object? decoded = jsonDecode(text);
    final Map<String, dynamic>? json = asMap(decoded);
    if (json == null) throw const FormatException('signaling frame is not a JSON object');
    return fromJson(json);
  }

  static ServerMessage fromJson(Map<String, dynamic> json) {
    final String? t = asString(json['t']);
    if (t == null || t.isEmpty) throw const FormatException('signaling frame has no "t"');
    switch (t) {
      case 'hello':
        return HelloMessage.fromJson(json);
      case 'incoming':
        return IncomingMessage.fromJson(json);
      case 'joined':
        return JoinedMessage.fromJson(json);
      case 'peer_joined':
        return PeerJoinedMessage.fromJson(json);
      case 'peer_left':
        return PeerLeftMessage.fromJson(json);
      case 'signal':
        return SignalMessage.fromJson(json);
      case 'state':
        return StateMessage.fromJson(json);
      case 'ice_refresh':
        return IceRefreshMessage.fromJson(json);
      case 'error':
        return ErrorMessage.fromJson(json);
      case 'ping':
        return PingMessage.fromJson(json);
      case 'pong':
        return PongMessage(json);
      default:
        return UnknownMessage(json);
    }
  }
}

/// First frame after the socket opens.
class HelloMessage extends ServerMessage {
  HelloMessage._(super.raw, this.you, this.iceServers, this.iceTtl, this.maxParticipants, this.resume, this.resumeAll);

  factory HelloMessage.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic>? limits = asMap(json['limits']);
    final List<Map<String, dynamic>> all = <Map<String, dynamic>>[];
    for (final Object? r in asList(json['resume_all'])) {
      final Map<String, dynamic>? m = asMap(r);
      if (m != null) all.add(m);
    }
    return HelloMessage._(
      json,
      asString(json['you']) ?? asString(asMap(json['you'])?['user_id']),
      IceServer.listFromJson(json['ice_servers']),
      asInt(json['ice_ttl']),
      limits == null ? null : asInt(limits['max_participants']),
      json['resume'],
      all,
    );
  }

  /// The external user id this token belongs to (a string on the wire).
  final String? you;

  /// STUN only. TURN credentials come per call in [JoinedMessage.iceServers].
  final List<IceServer> iceServers;
  final int? iceTtl;
  final int? maxParticipants;

  /// `{call_id, pid}` of the first participant of this user in its
  /// reconnect grace; absent when there is none.
  final Object? resume;

  /// Every `{call_id, pid}` this user can resume.
  final List<Map<String, dynamic>> resumeAll;

  /// The pid to resume for [callId] (from `resume_all`, else `resume`) —
  /// lets a client that never learned its pid still resume.
  String? resumePidFor(String callId) {
    for (final Map<String, dynamic> r in <Map<String, dynamic>>[...resumeAll, if (asMap(resume) != null) asMap(resume)!]) {
      if (asString(r['call_id']) == callId) {
        final String? pid = _nonEmpty(asString(r['pid']));
        if (pid != null) return pid;
      }
    }
    return null;
  }
}

class IncomingMessage extends ServerMessage {
  IncomingMessage._(super.raw, this.call);

  factory IncomingMessage.fromJson(Map<String, dynamic> json) =>
      IncomingMessage._(json, CallInfo.fromJson(asMap(json['call']) ?? <String, dynamic>{}));

  final CallInfo call;
}

/// Reply to `join` / `accept` (and possibly to `resume`).
class JoinedMessage extends ServerMessage {
  JoinedMessage._(super.raw, this.call, this.pid, this.peers, this.politeFor, this.provider, this.iceServers,
      this.iceTtl, this.resume);

  factory JoinedMessage.fromJson(Map<String, dynamic> json) {
    final Map<String, dynamic> callJson = asMap(json['call']) ?? <String, dynamic>{};
    final CallInfo call = CallInfo.fromJson(callJson);
    final List<PeerInfo> peers = <PeerInfo>[];
    for (final Object? p in asList(json['peers'])) {
      final Map<String, dynamic>? m = asMap(p);
      if (m == null) continue;
      final PeerInfo peer = PeerInfo.fromJson(m);
      if (peer.pid.isNotEmpty) peers.add(peer);
    }
    final Map<String, bool> polite = <String, bool>{};
    final Map<String, dynamic>? pf = asMap(json['polite_for']);
    if (pf != null) {
      pf.forEach((String k, dynamic v) {
        final bool? b = asBool(v);
        if (b != null) polite[k] = b;
      });
    }
    // Our own participant id. The contract names it on `resume { call_id, pid }`;
    // accept the common spellings the server may use on `joined`.
    final String? pid = _nonEmpty(asString(json['pid'])) ??
        _nonEmpty(asString(asMap(json['you'])?['pid'])) ??
        _nonEmpty(asString(asMap(json['self'])?['pid'])) ??
        _nonEmpty(asString(callJson['pid'])) ??
        _nonEmpty(asString(asMap(json['participant'])?['pid']));
    final Map<String, dynamic>? prov = asMap(json['provider']);
    return JoinedMessage._(
      json,
      call,
      pid,
      peers,
      polite,
      prov == null ? null : ProviderInfo.fromJson(call.id, prov),
      json['ice_servers'] is List ? IceServer.listFromJson(json['ice_servers']) : null,
      asInt(json['ice_ttl']),
      asBool(json['resume']) ?? false,
    );
  }

  final CallInfo call;

  /// This client's participant id, when the server includes it.
  final String? pid;

  /// Participants already in the call (this client offers to each of them).
  final List<PeerInfo> peers;

  /// `polite_for[pid] == true` means THIS client is the polite side towards
  /// that peer.
  final Map<String, bool> politeFor;

  /// Present when the call runs on a third-party provider.
  final ProviderInfo? provider;

  /// STUN + TURN with credentials scoped to this call and participant
  /// (engine catz only; null when absent). Use these for the call's peer
  /// connections.
  final List<IceServer>? iceServers;
  final int? iceTtl;

  /// True when this answers a `resume` (nothing is renegotiated).
  final bool resume;
}

String? _nonEmpty(String? s) => (s == null || s.isEmpty) ? null : s;

class PeerJoinedMessage extends ServerMessage {
  PeerJoinedMessage._(super.raw, this.callId, this.peer);

  factory PeerJoinedMessage.fromJson(Map<String, dynamic> json) =>
      PeerJoinedMessage._(json, asString(json['call_id']) ?? '', PeerInfo.fromJson(json));

  final String callId;
  final PeerInfo peer;
}

class PeerLeftMessage extends ServerMessage {
  PeerLeftMessage._(super.raw, this.callId, this.peer, this.reason);

  factory PeerLeftMessage.fromJson(Map<String, dynamic> json) => PeerLeftMessage._(
        json,
        asString(json['call_id']) ?? '',
        PeerInfo.fromJson(json),
        asString(json['reason']),
      );

  final String callId;
  final PeerInfo peer;
  final String? reason;
}

/// Opaque WebRTC payload relayed from another participant.
class SignalMessage extends ServerMessage {
  SignalMessage._(super.raw, this.callId, this.from, this.data);

  factory SignalMessage.fromJson(Map<String, dynamic> json) => SignalMessage._(
        json,
        asString(json['call_id']) ?? '',
        asString(json['from']) ?? '',
        SignalData.fromJson(asMap(json['data']) ?? <String, dynamic>{}),
      );

  final String callId;

  /// Sender's pid.
  final String from;
  final SignalData data;
}

class StateMessage extends ServerMessage {
  StateMessage._(super.raw, this.event);

  factory StateMessage.fromJson(Map<String, dynamic> json) => StateMessage._(
        json,
        CallStateEvent(
          callId: asString(json['call_id']) ?? '',
          status: CallStatus.parse(json['status']),
          reason: asString(json['reason']),
        ),
      );

  final CallStateEvent event;
}

class IceRefreshMessage extends ServerMessage {
  IceRefreshMessage._(super.raw, this.callId, this.iceServers, this.iceTtl);

  factory IceRefreshMessage.fromJson(Map<String, dynamic> json) => IceRefreshMessage._(
      json, _nonEmpty(asString(json['call_id'])), IceServer.listFromJson(json['ice_servers']), asInt(json['ice_ttl']));

  /// The call these credentials are for.
  final String? callId;
  final List<IceServer> iceServers;
  final int? iceTtl;
}

class ErrorMessage extends ServerMessage {
  ErrorMessage._(super.raw, this.error);

  factory ErrorMessage.fromJson(Map<String, dynamic> json) => ErrorMessage._(
        json,
        CallError(
          asString(json['code']) ?? 'error',
          asString(json['message']) ?? 'Unknown error',
          callId: asString(json['call_id']),
        ),
      );

  final CallError error;
}

class PingMessage extends ServerMessage {
  PingMessage._(super.raw, this.ts);

  factory PingMessage.fromJson(Map<String, dynamic> json) => PingMessage._(json, json['ts']);

  /// Echoed back unchanged in `pong`.
  final Object? ts;
}

/// The server's answer to a client `ping`.
class PongMessage extends ServerMessage {
  const PongMessage(super.raw);
}

/// A frame type this SDK version does not know. Ignored by the client.
class UnknownMessage extends ServerMessage {
  const UnknownMessage(super.raw);
}

// ---------------------------------------------------------------------------
// Signal payloads (`signal.data`)
// ---------------------------------------------------------------------------

/// Session description inside a signal.
class SdpPayload {
  const SdpPayload({required this.type, required this.sdp});

  /// `offer` or `answer`.
  final String type;
  final String sdp;

  Map<String, dynamic> toJson() => <String, dynamic>{'type': type, 'sdp': sdp};
}

/// ICE candidate inside a signal (same shape as the browser's
/// `RTCIceCandidate.toJSON()`).
class CandidatePayload {
  const CandidatePayload({required this.candidate, this.sdpMid, this.sdpMLineIndex});

  final String candidate;
  final String? sdpMid;
  final int? sdpMLineIndex;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'candidate': candidate,
        'sdpMid': sdpMid,
        'sdpMLineIndex': sdpMLineIndex,
      };
}

/// One of `{ sdp }`, `{ candidate }` or `{ restart: true }`.
class SignalData {
  const SignalData({this.sdp, this.candidate, this.restart = false, this.raw = const <String, dynamic>{}});

  final SdpPayload? sdp;
  final CandidatePayload? candidate;

  /// The other side asks this client to perform an ICE restart.
  final bool restart;
  final Map<String, dynamic> raw;

  factory SignalData.description(String type, String sdp) => SignalData(sdp: SdpPayload(type: type, sdp: sdp));

  factory SignalData.iceCandidate(String candidate, String? sdpMid, int? sdpMLineIndex) => SignalData(
      candidate: CandidatePayload(candidate: candidate, sdpMid: sdpMid, sdpMLineIndex: sdpMLineIndex));

  factory SignalData.restartRequest() => const SignalData(restart: true);

  factory SignalData.fromJson(Map<String, dynamic> json) {
    SdpPayload? sdp;
    final Map<String, dynamic>? s = asMap(json['sdp']);
    if (s != null) {
      final String? type = asString(s['type']);
      final String? body = asString(s['sdp']);
      if (type != null && body != null) sdp = SdpPayload(type: type, sdp: body);
    }
    CandidatePayload? cand;
    final Map<String, dynamic>? c = asMap(json['candidate']);
    if (c != null) {
      final String? line = asString(c['candidate']);
      if (line != null && line.isNotEmpty) {
        cand = CandidatePayload(
          candidate: line,
          sdpMid: asString(c['sdpMid']),
          sdpMLineIndex: asInt(c['sdpMLineIndex']),
        );
      }
    }
    return SignalData(sdp: sdp, candidate: cand, restart: asBool(json['restart']) ?? false, raw: json);
  }

  Map<String, dynamic> toJson() {
    if (sdp != null) return <String, dynamic>{'sdp': sdp!.toJson()};
    if (candidate != null) return <String, dynamic>{'candidate': candidate!.toJson()};
    if (restart) return <String, dynamic>{'restart': true};
    return Map<String, dynamic>.from(raw);
  }

  bool get isEmpty => sdp == null && candidate == null && !restart;
}

// ---------------------------------------------------------------------------
// Client → server
// ---------------------------------------------------------------------------

/// An outgoing frame.
class ClientMessage {
  const ClientMessage(this.type, this.fields);

  final String type;
  final Map<String, dynamic> fields;

  static ClientMessage join(String callId, {required bool audio, required bool video, String? platform}) =>
      ClientMessage(
        'join',
        <String, dynamic>{
          'call_id': callId,
          'media': <String, dynamic>{'audio': audio, 'video': video},
          if (platform != null) 'platform': platform,
        },
      );

  /// Callee answers a ringing call (server alias of join).
  static ClientMessage accept(String callId, {bool? audio, bool? video, String? platform}) => ClientMessage(
        'accept',
        <String, dynamic>{
          'call_id': callId,
          if (audio != null && video != null) 'media': <String, dynamic>{'audio': audio, 'video': video},
          if (platform != null) 'platform': platform,
        },
      );

  static ClientMessage decline(String callId) => ClientMessage('decline', <String, dynamic>{'call_id': callId});

  static ClientMessage leave(String callId) => ClientMessage('leave', <String, dynamic>{'call_id': callId});

  static ClientMessage cancel(String callId) => ClientMessage('cancel', <String, dynamic>{'call_id': callId});

  static ClientMessage signal(String callId, String to, SignalData data) => ClientMessage(
        'signal',
        <String, dynamic>{'call_id': callId, 'to': to, 'data': data.toJson()},
      );

  static ClientMessage stats(
    String callId, {
    required ConnectionType connection,
    double? rttMs,
    double? jitterMs,
    double? lossPct,
    double? bitrateKbps,
  }) {
    final Map<String, dynamic> f = <String, dynamic>{
      'call_id': callId,
      'connection': connection.wire,
    };
    // Unknown metrics are omitted rather than sent as null.
    if (rttMs != null) f['rtt_ms'] = rttMs.round();
    if (jitterMs != null) f['jitter_ms'] = jitterMs.round();
    if (lossPct != null) f['loss_pct'] = (lossPct * 100).round() / 100;
    if (bitrateKbps != null) f['bitrate_kbps'] = bitrateKbps.round();
    return ClientMessage('stats', f);
  }

  static ClientMessage pong(Object? ts) => ClientMessage('pong', <String, dynamic>{'ts': ts});

  static ClientMessage resume(String callId, String pid) =>
      ClientMessage('resume', <String, dynamic>{'call_id': callId, 'pid': pid});

  /// Whether the frame should be kept and sent later while the socket is
  /// reconnecting. Pongs and stats are only meaningful right now.
  bool get queueable => type != 'pong' && type != 'stats' && type != 'resume';

  Map<String, dynamic> toJson() => <String, dynamic>{'t': type, ...fields};

  String encode() => jsonEncode(toJson());

  @override
  String toString() => encode();
}

// ---------------------------------------------------------------------------
// Perfect negotiation
// ---------------------------------------------------------------------------

/// Whether this client is the *polite* side towards [otherPid]: the
/// participant with the lexicographically larger pid is polite. A
/// `polite_for` entry from the server always wins.
bool isPolite(String myPid, String otherPid, {Map<String, bool>? politeFor}) {
  final bool? fromServer = politeFor?[otherPid];
  if (fromServer != null) return fromServer;
  return myPid.compareTo(otherPid) > 0;
}

/// The `exp` (unix seconds) inside a `ct1.<payload>.<mac>` user token, or
/// null when the token has another shape. The signature is not checked
/// (only the server can); this is only used to renew tokens in time.
int? tokenExpiry(String token) {
  final List<String> parts = token.split('.');
  if (parts.length != 3 || parts[0] != 'ct1') return null;
  try {
    final List<int> bytes = base64Url.decode(base64Url.normalize(parts[1]));
    final Map<String, dynamic>? json = asMap(jsonDecode(utf8.decode(bytes)));
    if (json == null) return null;
    final Object? exp = json['exp'];
    return exp is num ? exp.toInt() : null;
  } catch (_) {
    return null;
  }
}

/// Error codes (on an `error` frame without `call_id`) meaning the token is
/// no good any more. Same list as the browser SDK.
const Set<String> kAuthErrorCodes = <String>{
  'unauthorized',
  'invalid_token',
  'token_expired',
  'token_revoked',
};

/// WebSocket close codes meaning the token was refused: 4401 (token refused,
/// API key revoked or without the Calls channel) and 4403 (forbidden). 1008
/// is a generic policy close and is not an auth failure.
const Set<int> kAuthCloseCodes = <int>{4401, 4403};

/// Close code for rate limit / server overload: reconnect with a longer
/// backoff, the token is fine.
const int kOverloadCloseCode = 4008;

/// Whether a session made for epoch [known] belongs to an earlier join of
/// that participant than [incoming] (it moved device: the old peer
/// connection must be replaced). Unknown epochs never count as stale.
bool isStalePeerEpoch(int? known, int? incoming) => known != null && incoming != null && known != incoming;

bool isAuthCloseCode(int? code) => code != null && kAuthCloseCodes.contains(code);

bool isAuthErrorCode(String? code) => code != null && kAuthErrorCodes.contains(code.toLowerCase());

/// Builds the signaling URL with the token as a query parameter.
Uri buildSocketUri(String url, String token) {
  final Uri base = Uri.parse(url);
  final Map<String, String> q = Map<String, String>.from(base.queryParameters);
  q['token'] = token;
  return base.replace(queryParameters: q);
}
