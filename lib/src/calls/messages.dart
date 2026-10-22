// In-call chat and app data messages: caps, rate limiting, de-duplication
// and the peer-to-peer envelope. Pure Dart (no Flutter / WebRTC imports), so
// it is unit-testable. Mirrors the browser SDK's `call/messages.ts`.
//
// Messages travel over a WebRTC data channel to each peer when it is open,
// and through the signaling server (`{"t":"chat"|"data"}`) otherwise. Every
// message has a sender-chosen `id`; receivers drop repeats of (sender pid,
// id), so a message that went both ways is shown once.
//
// Ordering: messages from one sender keep their order on one route, but the
// route can change between two messages (relay while a data channel is still
// opening, p2p once it is open), so a later message can overtake an earlier
// one. When order matters, sort by `ts` (the sender's clock, the same on both
// routes) or carry a sequence number in `data`.

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'models.dart';

/// Label of the ordered, reliable data channel the initiator of a peer
/// connection opens for in-call messages.
const String kReliableChannelLabel = 'catz-msg';

/// Label of the unordered, no-retransmit data channel.
const String kUnreliableChannelLabel = 'catz-msg-u';

/// How a message reached (or left) this client.
enum MessageVia {
  /// Over a WebRTC data channel, peer to peer.
  p2p,

  /// Through the signaling server.
  relay,
}

/// How [CatzCallClient.sendChat] / `sendData` deliver.
enum MessageTransport {
  /// Data channels when open, the signaling server otherwise (default).
  auto,

  /// Always through the signaling server.
  server,
}

/// Caps the server announces in `hello.limits` (these defaults otherwise).
class MessageLimits {
  const MessageLimits({
    this.chatMaxChars = 2000,
    this.dataMaxBytes = 16384,
    this.perSec = 5,
    this.burst = 20,
    this.relay = true,
  });

  /// Characters (Unicode code points) per chat text.
  final int chatMaxChars;

  /// Bytes of a data payload as compact JSON (UTF-8).
  final int dataMaxBytes;

  /// Messages (chat + data) per second per participant.
  final int perSec;

  /// Burst allowed above the rate.
  final int burst;

  /// Whether the server relays messages (else data channels only).
  final bool relay;

  /// Reads the caps from `hello.limits`; defaults for anything missing,
  /// except [relay]: it is true only when the server says so
  /// (`messages_relay: true`). A server from before in-call messages
  /// announces nothing and would refuse relayed messages, so they then go
  /// over data channels only.
  factory MessageLimits.fromJson(Map<String, dynamic>? limits) {
    const MessageLimits d = MessageLimits();
    final Map<String, dynamic> l = limits ?? const <String, dynamic>{};
    int n(String k, int def, int min, int max) {
      final Object? v = l[k];
      if (v is! num || !v.isFinite) return def;
      return v.floor().clamp(min, max).toInt();
    }

    final int perSec = n('messages_per_sec', d.perSec, 1, 1000);
    final int burst = n('messages_burst', d.burst, 1, 10000);
    final Object? relay = l['messages_relay'];
    return MessageLimits(
      chatMaxChars: n('chat_max_chars', d.chatMaxChars, 1, 100000),
      dataMaxBytes: n('data_max_bytes', d.dataMaxBytes, 1, 1000000),
      perSec: perSec,
      burst: burst < perSec ? perSec : burst,
      relay: relay is bool && relay,
    );
  }

  /// A copy with [relay] replaced.
  MessageLimits withRelay(bool relay) =>
      MessageLimits(chatMaxChars: chatMaxChars, dataMaxBytes: dataMaxBytes, perSec: perSec, burst: burst, relay: relay);

  @override
  bool operator ==(Object other) =>
      other is MessageLimits &&
      other.chatMaxChars == chatMaxChars &&
      other.dataMaxBytes == dataMaxBytes &&
      other.perSec == perSec &&
      other.burst == burst &&
      other.relay == relay;

  @override
  int get hashCode => Object.hash(chatMaxChars, dataMaxBytes, perSec, burst, relay);
}

/// An in-call message (chat / data) that was refused: thrown by `sendChat`
/// / `sendData` before it left this client (`not_in_call`, `bad_request`,
/// `message_too_large`, `rate_limited`, `no_route`), or emitted on
/// `CatzCallClient.errors` when the server refused it (with [messageId]:
/// `rate_limited`, `message_too_large`, `peer_unavailable`,
/// `messages_disabled`, `not_joined`, `bad_request`).
class CallMessageError extends CallError {
  const CallMessageError(super.code, super.message, {super.callId, this.messageId});

  /// The refused message's id (server refusals).
  final String? messageId;

  @override
  String toString() => 'CallMessageError($code): $message';
}

final RegExp _idRe = RegExp(r'^[A-Za-z0-9_.:\-]{1,64}$');

/// Whether [id] is a valid message id (1–64 of `A-Z a-z 0-9 _ - . :`).
bool isValidMessageId(Object? id) => id is String && _idRe.hasMatch(id);

/// A new random message id.
String newMessageId([Random? random, DateTime? now]) {
  final Random r = random ?? Random.secure();
  const String chars = '0123456789abcdefghijklmnopqrstuvwxyz';
  final StringBuffer b = StringBuffer((now ?? DateTime.now()).millisecondsSinceEpoch.toRadixString(36))..write('-');
  for (int i = 0; i < 12; i++) {
    b.write(chars[r.nextInt(chars.length)]);
  }
  return b.toString();
}

// C0 / C1 control characters except tab, newline, carriage return.
final RegExp _controlRe = RegExp('[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f-\u009f]');

/// Why a chat text is refused, or null when it is fine.
CallMessageError? checkChat(Object? text, MessageLimits l) {
  if (text is! String || text.trim().isEmpty) return const CallMessageError('bad_request', 'Chat text is empty.');
  if (text.runes.length > l.chatMaxChars) {
    return CallMessageError('message_too_large', 'Chat text is longer than ${l.chatMaxChars} characters.');
  }
  if (_controlRe.hasMatch(text)) {
    return const CallMessageError('bad_request', 'Chat text contains control characters.');
  }
  return null;
}

/// Encodes a data payload as compact JSON, or returns why it is refused.
({CallMessageError? error, String json}) checkData(Object? payload, MessageLimits l) {
  if (payload == null) return (error: const CallMessageError('bad_request', 'Data payload is empty.'), json: '');
  final String json;
  try {
    json = jsonEncode(payload);
  } catch (_) {
    return (error: const CallMessageError('bad_request', 'Data payload is not JSON.'), json: '');
  }
  if (utf8.encode(json).length > l.dataMaxBytes) {
    return (
      error: CallMessageError('message_too_large', 'Data payload is larger than ${l.dataMaxBytes} bytes.'),
      json: json,
    );
  }
  return (error: null, json: json);
}

/// Token bucket: [MessageLimits.perSec] per second, up to
/// [MessageLimits.burst].
class RateBucket {
  RateBucket(this._limits) : _tokens = _limits.burst.toDouble();

  final MessageLimits _limits;
  double _tokens;
  DateTime? _at;

  bool take([DateTime? now]) {
    final DateTime t = now ?? DateTime.now();
    final DateTime? at = _at;
    if (at != null) {
      final double dt = t.difference(at).inMicroseconds / 1e6;
      _tokens = min(_limits.burst.toDouble(), _tokens + (dt < 0 ? 0 : dt) * _limits.perSec);
    }
    _at = t;
    if (_tokens >= 1) {
      _tokens -= 1;
      return true;
    }
    return false;
  }
}

/// Remembers the last [max] keys; [seen] is true for a repeat.
class Dedup {
  Dedup([this.max = 1024]);

  final int max;
  final LinkedHashSet<String> _keys = LinkedHashSet<String>();

  bool seen(String key) {
    if (_keys.contains(key)) return true;
    _keys.add(key);
    if (_keys.length > max) _keys.remove(_keys.first);
    return false;
  }

  void clear() => _keys.clear();
}

/// What goes over a data channel (JSON text).
class PeerEnvelope {
  const PeerEnvelope({
    required this.kind,
    required this.id,
    required this.ts,
    this.to,
    this.text,
    this.payload,
    this.reliable = true,
  });

  /// `chat` or `data`.
  final String kind;
  final String id;

  /// Sender's clock, ms since epoch.
  final int ts;

  /// The recipient's pid for a private message, null for everyone.
  final String? to;
  final String? text;
  final Object? payload;
  final bool reliable;

  String encode() => jsonEncode(<String, dynamic>{
        'v': 1,
        'k': kind,
        'id': id,
        'ts': ts,
        'to': to,
        if (kind == 'chat') 'text': text,
        if (kind == 'data') 'payload': payload,
        if (kind == 'data') 'reliable': reliable,
      });

  /// Decodes and checks a data-channel message against the caps. Null for
  /// anything malformed or over a cap (dropped silently).
  static PeerEnvelope? decode(Object? raw, MessageLimits l) {
    if (raw is! String || raw.length > 4 * (l.dataMaxBytes + l.chatMaxChars) + 1024) return null;
    final Map<String, dynamic>? e;
    try {
      e = asMap(jsonDecode(raw));
    } catch (_) {
      return null;
    }
    if (e == null || e['v'] != 1 || !isValidMessageId(e['id'])) return null;
    final int ts = epochMsOrNull(e['ts']) ?? 0;
    final Object? toRaw = e['to'];
    final String? to = toRaw is String ? toRaw : null;
    final String id = e['id'] as String;
    if (e['k'] == 'chat') {
      if (checkChat(e['text'], l) != null) return null;
      return PeerEnvelope(kind: 'chat', id: id, ts: ts, to: to, text: e['text'] as String);
    }
    if (e['k'] == 'data') {
      if (checkData(e['payload'], l).error != null) return null;
      return PeerEnvelope(kind: 'data', id: id, ts: ts, to: to, payload: e['payload'], reliable: e['reliable'] != false);
    }
    return null;
  }
}

/// The route of an outgoing message.
enum MessageRoute { p2p, relay, none }

/// `p2p` when every target has an open data channel (and the app did not
/// ask for server delivery), else `relay` (when the server relays); `none`
/// when neither can carry it. Without relay, what is open goes p2p.
MessageRoute chooseRoute(List<bool> targetsOpen, {required bool forceServer, required bool serverRelay}) {
  if (!forceServer && targetsOpen.isNotEmpty && targetsOpen.every((bool o) => o)) return MessageRoute.p2p;
  if (serverRelay) return MessageRoute.relay;
  return !forceServer && targetsOpen.any((bool o) => o) ? MessageRoute.p2p : MessageRoute.none;
}

/// An in-call chat message from another participant.
class CallChatMessage {
  const CallChatMessage({
    required this.callId,
    required this.id,
    required this.from,
    required this.userId,
    required this.text,
    required this.to,
    required this.ts,
    required this.via,
  });

  final String callId;

  /// Sender-chosen id (unique per sender).
  final String id;

  /// Sender's pid.
  final String from;

  /// Sender's user id ('' when not known yet).
  final String userId;
  final String text;

  /// This client's pid when sent to it alone; null when sent to everyone.
  final String? to;

  /// True when it was sent to this participant only.
  bool get isPrivate => to != null;

  /// Send time (the server's clock when relayed, the sender's when p2p).
  final DateTime ts;
  final MessageVia via;
}

/// App-defined data from another participant (any JSON value).
class CallDataMessage {
  const CallDataMessage({
    required this.callId,
    required this.id,
    required this.from,
    required this.userId,
    required this.payload,
    required this.to,
    required this.ts,
    required this.via,
  });

  final String callId;
  final String id;
  final String from;
  final String userId;
  final Object? payload;
  final String? to;
  bool get isPrivate => to != null;
  final DateTime ts;
  final MessageVia via;
}

/// What `sendChat` / `sendData` did with a message.
class SentCallMessage {
  const SentCallMessage({required this.id, required this.ts, required this.via, this.to});

  final String id;
  final DateTime ts;

  /// [MessageVia.relay]: through the server (queued while signaling
  /// reconnects, except unreliable data).
  final MessageVia via;
  final String? to;
}

/// Largest |milliseconds since epoch| a [DateTime] can hold.
const int _kMaxEpochMs = 8640000000000000;

/// A sender's `ts` (ms since epoch) when it is a number a [DateTime] can
/// hold; null otherwise (another participant chooses it).
int? epochMsOrNull(Object? v) {
  if (v is! num || !v.isFinite || v.abs() > _kMaxEpochMs) return null;
  return v.toInt();
}

/// The time of a received message: the sender's `ts`, or local time when it
/// is missing or out of [DateTime]'s range (never throws).
DateTime messageTime(int? ms) {
  if (ms == null || ms > _kMaxEpochMs || ms < -_kMaxEpochMs) return DateTime.now();
  return DateTime.fromMillisecondsSinceEpoch(ms);
}

/// True for the refusal a server without in-call messages sends for a
/// `chat` / `data` frame (`bad_request`, `Unknown message type "chat"`, no
/// message id). It answers a message, not a join or resume.
bool isUnsupportedMessageError(String code, String message) =>
    code == 'bad_request' && RegExp(r'^Unknown message type "(chat|data)"$').hasMatch(message.trim());
