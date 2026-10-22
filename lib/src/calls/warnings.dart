// Call warnings: the server's `warning` / `warning_cleared` frames and the
// client's own checks (network, CPU, outgoing video). Same rules as the
// browser SDK.
//
// Pure Dart: no Flutter / WebRTC imports, so it is unit-testable.

import 'models.dart';

/// Known warning codes. Other codes may come from newer servers and are
/// passed through unchanged ([CallWarning.code] is a plain string).
abstract final class CallWarningCodes {
  /// Server: a peer-to-peer call has many participants; quality may drop.
  static const String largeCall = 'large_call';

  /// Server: the TURN relay is near capacity.
  static const String relayBusy = 'relay_busy';

  /// Server: the relay is down or refused this participant; the call may
  /// not connect behind strict firewalls.
  static const String relayUnavailable = 'relay_unavailable';

  /// Client: weak uplink (estimated bandwidth below what the peers need,
  /// loss > 8 % or RTT > 600 ms for 6 s).
  static const String poorNetwork = 'poor_network';

  /// Client: the video encoder is limited by CPU for 6 s.
  static const String deviceOverloaded = 'device_overloaded';

  /// Client (info): the SDK lowered outgoing video bitrate / resolution.
  static const String videoReduced = 'video_reduced';

  /// Client: the SDK stopped sending video to keep audio working.
  static const String videoPaused = 'video_paused';

  static const List<String> known = <String>[
    largeCall,
    relayBusy,
    relayUnavailable,
    poorNetwork,
    deviceOverloaded,
    videoReduced,
    videoPaused,
  ];
}

/// English defaults for the known codes. Localise by [CallWarning.code].
const Map<String, String> kDefaultWarningMessages = <String, String>{
  CallWarningCodes.largeCall: 'Call quality may drop — many people are in this call',
  CallWarningCodes.relayBusy: 'The call relay is busy; the call may not connect on some networks',
  CallWarningCodes.relayUnavailable: "Calls aren't available on this network right now",
  CallWarningCodes.poorNetwork: 'Your connection is weak',
  CallWarningCodes.deviceOverloaded: 'Your device is overloaded; video quality was lowered',
  CallWarningCodes.videoReduced: 'Video quality was lowered to fit your connection',
  CallWarningCodes.videoPaused: 'Your video is paused to keep audio clear',
};

/// The default English text for [code] (`Call warning: <code>` when unknown).
String defaultWarningMessage(String code) => kDefaultWarningMessages[code] ?? 'Call warning: $code';

/// Where a warning comes from.
enum CallWarningSource {
  server,
  client;

  String get wire => name;
}

/// How serious a warning is: [info] for `video_reduced`, else [warning].
enum CallWarningSeverity { info, warning }

CallWarningSeverity warningSeverity(String code) =>
    code == CallWarningCodes.videoReduced ? CallWarningSeverity.info : CallWarningSeverity.warning;

/// Something may degrade the call.
class CallWarning {
  const CallWarning({
    required this.code,
    required this.message,
    required this.callId,
    required this.source,
    required this.at,
    this.participants,
    this.severity = CallWarningSeverity.warning,
  });

  /// A [CallWarningCodes] value or a newer code.
  final String code;

  /// English default text; localise by [code].
  final String message;
  final String callId;

  /// Participants in the call, when known.
  final int? participants;
  final CallWarningSource source;
  final CallWarningSeverity severity;

  /// When it was raised.
  final DateTime at;

  CallWarning copyWith({DateTime? at}) => CallWarning(
        code: code,
        message: message,
        callId: callId,
        source: source,
        at: at ?? this.at,
        participants: participants,
        severity: severity,
      );

  @override
  String toString() => 'CallWarning($code, ${source.name}, call $callId, participants $participants)';
}

/// A warning is over.
class CallWarningCleared {
  const CallWarningCleared({required this.code, required this.callId, required this.source, required this.at});

  final String code;
  final String callId;
  final CallWarningSource source;
  final DateTime at;

  @override
  String toString() => 'CallWarningCleared($code, ${source.name}, call $callId)';
}

/// Reads a server `warning` frame. Null when it is not one or has no code /
/// call id ([fallbackCallId] is used when `call_id` is missing).
CallWarning? parseWarning(Map<String, dynamic> json, DateTime now, {String? fallbackCallId}) {
  if (asString(json['t']) != 'warning') return null;
  final String code = (asString(json['code']) ?? '').trim();
  if (code.isEmpty) return null;
  final String? cid = asString(json['call_id']);
  final String callId = (cid != null && cid.isNotEmpty) ? cid : (fallbackCallId ?? '');
  if (callId.isEmpty) return null;
  final int? n = asInt(json['participants']);
  final String? msg = asString(json['message']);
  return CallWarning(
    code: code,
    message: (msg != null && msg.trim().isNotEmpty) ? msg : defaultWarningMessage(code),
    callId: callId,
    participants: (n != null && n >= 0) ? n : null,
    source: CallWarningSource.server,
    severity: warningSeverity(code),
    at: now,
  );
}

/// Reads a server `warning_cleared` frame. Null when it is not one.
CallWarningCleared? parseWarningCleared(Map<String, dynamic> json, DateTime now, {String? fallbackCallId}) {
  if (asString(json['t']) != 'warning_cleared') return null;
  final String code = (asString(json['code']) ?? '').trim();
  if (code.isEmpty) return null;
  final String? cid = asString(json['call_id']);
  final String callId = (cid != null && cid.isNotEmpty) ? cid : (fallbackCallId ?? '');
  if (callId.isEmpty) return null;
  return CallWarningCleared(code: code, callId: callId, source: CallWarningSource.server, at: now);
}

// ---------------------------------------------------------------------------
// Hysteresis
// ---------------------------------------------------------------------------

/// Transition reported by [SustainedFlag.update].
enum FlagChange { enter, exit }

/// A condition that turns on only after it was bad for [enter] and off only
/// after it was good for [exit]. [update] reports each transition once, so
/// warnings are not spammed.
class SustainedFlag {
  SustainedFlag({this.enter = const Duration(seconds: 6), this.exit = const Duration(seconds: 6)});

  final Duration enter;
  final Duration exit;
  bool active = false;
  DateTime? _since;

  FlagChange? update(bool bad, DateTime now) {
    final bool wantChange = active ? !bad : bad;
    if (!wantChange) {
      _since = null;
      return null;
    }
    final DateTime since = _since ??= now;
    if (now.difference(since) < (active ? exit : enter)) return null;
    _since = null;
    active = !active;
    return active ? FlagChange.enter : FlagChange.exit;
  }

  void reset() {
    active = false;
    _since = null;
  }
}

/// Thresholds for `poor_network`: enter above the *Enter* values, leave
/// only below the stricter *Exit* values.
class NetworkThresholds {
  const NetworkThresholds({
    this.lossEnterPct = 8,
    this.lossExitPct = 4,
    this.rttEnterMs = 600,
    this.rttExitMs = 400,
    this.bitrateExitFactor = 1.2,
  });

  final double lossEnterPct;
  final double lossExitPct;
  final double rttEnterMs;
  final double rttExitMs;

  /// Leave only when the available bitrate is this many times what is needed.
  final double bitrateExitFactor;
}

/// Audio needs about this much per peer (Opus plus overhead).
const double kAudioKbpsPerPeer = 40;

/// The least video bitrate per peer worth sending.
const double kMinVideoKbps = 150;

/// The most video bitrate per peer in a multi-peer call.
const double kMaxVideoKbps = 1500;

/// The uplink (kbps) the current peers need: audio for each, plus minimal
/// video when sending video.
double requiredKbps(int peers, {required bool sendingVideo}) =>
    (peers < 0 ? 0 : peers) * (kAudioKbpsPerPeer + (sendingVideo ? kMinVideoKbps : 0));

/// Whether the network counts as bad for this sample. While [active] the
/// stricter exit thresholds apply, so the warning does not flap.
bool networkBad({
  required double? availableKbps,
  required double neededKbps,
  required double? lossPct,
  required double? rttMs,
  required bool active,
  NetworkThresholds t = const NetworkThresholds(),
}) {
  if (!active) {
    if (lossPct != null && lossPct > t.lossEnterPct) return true;
    if (rttMs != null && rttMs > t.rttEnterMs) return true;
    if (availableKbps != null && neededKbps > 0 && availableKbps < neededKbps) return true;
    return false;
  }
  final bool lossOk = lossPct == null || lossPct < t.lossExitPct;
  final bool rttOk = rttMs == null || rttMs < t.rttExitMs;
  final bool bwOk = availableKbps == null || neededKbps <= 0 || availableKbps >= neededKbps * t.bitrateExitFactor;
  return !(lossOk && rttOk && bwOk);
}

// ---------------------------------------------------------------------------
// Outgoing video budget
// ---------------------------------------------------------------------------

/// One step of outgoing video per peer.
class VideoLevel {
  const VideoLevel(this.maxKbps, this.scaleResolutionDownBy);

  final double maxKbps;
  final double scaleResolutionDownBy;
}

/// Steps of outgoing video per peer, best first.
const List<VideoLevel> kVideoLevels = <VideoLevel>[
  VideoLevel(1500, 1),
  VideoLevel(1000, 1),
  VideoLevel(600, 1.5),
  VideoLevel(300, 2),
  VideoLevel(150, 3),
];

/// Level index meaning "video paused".
const int kVideoPaused = 5;

/// The level for a per-peer budget: the best step whose bitrate fits, or
/// [kVideoPaused] under 150 kbps.
int levelFor(double perPeerKbps) {
  if (perPeerKbps.isNaN || perPeerKbps < kMinVideoKbps) return kVideoPaused;
  for (int i = 0; i < kVideoLevels.length; i++) {
    if (perPeerKbps >= kVideoLevels[i].maxKbps) return i;
  }
  return kVideoLevels.length - 1;
}

/// The outgoing video budget per peer.
class VideoBudget {
  const VideoBudget({
    required this.perPeerKbps,
    required this.maxBitrateKbps,
    required this.scaleResolutionDownBy,
    required this.paused,
    required this.level,
  });

  /// available / peers.
  final double perPeerKbps;

  /// clamp(perPeerKbps, 150, 1500).
  final double maxBitrateKbps;

  /// 1 · 1.5 · 2 · 3 as the per-peer budget shrinks.
  final double scaleResolutionDownBy;

  /// Under 150 kbps per peer: send no video.
  final bool paused;

  /// Index into [kVideoLevels], or [kVideoPaused].
  final int level;
}

/// Splits the available outgoing bitrate across the peers:
/// clamp(available / peers, 150 kbps, 1.5 Mbps).
VideoBudget videoBudget(double availableKbps, int peers) {
  final double per = availableKbps / (peers < 1 ? 1 : peers);
  final int level = levelFor(per);
  final double clamped = per.isNaN ? kMinVideoKbps : per.clamp(kMinVideoKbps, kMaxVideoKbps).toDouble();
  return VideoBudget(
    perPeerKbps: per,
    maxBitrateKbps: clamped.roundToDouble(),
    scaleResolutionDownBy:
        level == kVideoPaused ? kVideoLevels.last.scaleResolutionDownBy : kVideoLevels[level].scaleResolutionDownBy,
    paused: level == kVideoPaused,
    level: level,
  );
}

/// What the video senders should be set to. A null [maxBitrateKbps]
/// leaves the platform's own limit.
class VideoTarget {
  const VideoTarget({
    required this.level,
    required this.maxBitrateKbps,
    required this.scaleResolutionDownBy,
    required this.active,
  });

  final int level;
  final double? maxBitrateKbps;
  final double scaleResolutionDownBy;
  final bool active;

  /// True when this is the platform default (nothing to shape).
  bool get isDefault => maxBitrateKbps == null && scaleResolutionDownBy <= 1 && active;

  String get key => '$maxBitrateKbps|$scaleResolutionDownBy|$active';

  @override
  bool operator ==(Object other) =>
      other is VideoTarget &&
      other.level == level &&
      other.maxBitrateKbps == maxBitrateKbps &&
      other.scaleResolutionDownBy == scaleResolutionDownBy &&
      other.active == active;

  @override
  int get hashCode => Object.hash(level, maxBitrateKbps, scaleResolutionDownBy, active);

  @override
  String toString() => 'VideoTarget(level $level, $maxBitrateKbps kbps, /$scaleResolutionDownBy, active $active)';
}

VideoTarget videoTarget(int level, int peers) {
  if (level >= kVideoPaused) {
    final VideoLevel last = kVideoLevels.last;
    return VideoTarget(
        level: kVideoPaused, maxBitrateKbps: last.maxKbps, scaleResolutionDownBy: last.scaleResolutionDownBy, active: false);
  }
  final int l = level < 0 ? 0 : level;
  // A 1:1 call on a good link keeps the platform's own limits.
  if (l == 0 && peers <= 1) {
    return const VideoTarget(level: 0, maxBitrateKbps: null, scaleResolutionDownBy: 1, active: true);
  }
  final VideoLevel v = kVideoLevels[l];
  return VideoTarget(level: l, maxBitrateKbps: v.maxKbps, scaleResolutionDownBy: v.scaleResolutionDownBy, active: true);
}

/// What [VideoAdapter.update] asks the client to announce.
enum AdaptChange { reduced, restored, paused, resumed }

/// Picks the outgoing video level from bandwidth estimates (same rules as
/// the browser SDK):
///
/// - 2+ peers: steps down when the per-peer budget (available / peers)
///   stays under 75 % of the current cap for [downAfter]; steps up one level
///   when the budget fills the current cap (≥ 85 %) with low loss for
///   [upAfter] (doubling, up to 160 s, after a step up that fails within
///   30 s).
/// - 1 peer: the platform's congestion control handles the bitrate; the
///   adapter only pauses video.
/// - Under 150 kbps per peer: video is paused, and retried with backoff
///   ([retry], doubling up to [maxRetry]) once loss and RTT are low.
class VideoAdapter {
  VideoAdapter({
    this.warmup = const Duration(seconds: 10),
    this.downAfter = const Duration(seconds: 4),
    this.upAfter = const Duration(seconds: 10),
    this.retry = const Duration(seconds: 15),
    this.maxRetry = const Duration(seconds: 60),
  })  : _retryDelay = retry,
        _upDelay = upAfter;

  final Duration warmup;
  final Duration downAfter;
  final Duration upAfter;
  final Duration retry;
  final Duration maxRetry;

  static const double _stayFactor = 0.75;
  static const double _upFactor = 0.85;
  static const Duration _probeWindow = Duration(seconds: 30);
  static const Duration _maxUpDelay = Duration(seconds: 160);

  int level = 0;
  DateTime? _firstAt;
  DateTime? _downSince;
  DateTime? _upSince;
  DateTime? _pausedAt;
  DateTime? _lastUpAt;
  Duration _retryDelay;
  Duration _upDelay;

  bool get paused => level >= kVideoPaused;

  /// Video is below the best level (or paused).
  bool get reduced => level > 0;

  void reset() {
    level = 0;
    _firstAt = null;
    _downSince = null;
    _upSince = null;
    _pausedAt = null;
    _lastUpAt = null;
    _retryDelay = retry;
    _upDelay = upAfter;
  }

  static Duration _min(Duration a, Duration b) => a < b ? a : b;

  int _wanted(double per, int peers) {
    if (per < kMinVideoKbps) return kVideoPaused;
    if (peers <= 1) return 0;
    final int raw = levelFor(per);
    if (raw > level && level < kVideoPaused && per >= kVideoLevels[level].maxKbps * _stayFactor) return level;
    return raw;
  }

  /// One sample. [availableKbps] is the estimated total uplink (null when
  /// unknown). Returns the changes to announce, in order.
  List<AdaptChange> update({
    required DateTime now,
    required int peers,
    required double? availableKbps,
    required double? lossPct,
    required double? rttMs,
  }) {
    final List<AdaptChange> out = <AdaptChange>[];
    final DateTime first = _firstAt ??= now;
    if (now.difference(first) < warmup || availableKbps == null || peers <= 0) {
      _downSince = null;
      _upSince = null;
      return out;
    }
    final DateTime? lastUp = _lastUpAt;
    if (lastUp != null && now.difference(lastUp) >= _probeWindow) {
      _lastUpAt = null;
      _upDelay = upAfter;
    }
    final double per = availableKbps / peers;
    final int want = _wanted(per, peers);
    final bool lossLow = lossPct == null || lossPct < 3;
    final bool rttLow = rttMs == null || rttMs < 400;
    final int before = level;

    if (paused) {
      final DateTime pausedAt = _pausedAt ?? now;
      if (now.difference(pausedAt) >= _retryDelay && lossLow && rttLow) {
        level = peers <= 1 ? 0 : kVideoLevels.length - 1;
        final Duration doubled = _retryDelay * 2;
        _retryDelay = _min(maxRetry, doubled);
        _downSince = null;
        _upSince = null;
      }
    } else if (want > level) {
      _upSince = null;
      final DateTime since = _downSince ??= now;
      if (now.difference(since) >= downAfter) {
        level = want;
        _downSince = null;
        if (paused) _pausedAt = now;
        final DateTime? lu = _lastUpAt;
        if (lu != null && now.difference(lu) < _probeWindow) _upDelay = _min(_maxUpDelay, _upDelay * 2);
        _lastUpAt = null;
      }
    } else {
      _downSince = null;
      bool up = false;
      if (level > 0) {
        up = peers <= 1 || ((want < level || per >= kVideoLevels[level].maxKbps * _upFactor) && lossLow);
      }
      if (!up) {
        _upSince = null;
      } else {
        final DateTime since = _upSince ??= now;
        if (now.difference(since) >= (peers <= 1 ? downAfter : _upDelay)) {
          level = peers <= 1 ? 0 : level - 1;
          _upSince = null;
          _lastUpAt = now;
          if (level == 0) _retryDelay = retry;
        }
      }
    }

    final int after = level;
    if (before == after) return out;
    final bool wasPaused = before >= kVideoPaused;
    final bool isPaused = after >= kVideoPaused;
    if (!wasPaused && isPaused) {
      if (before == 0) out.add(AdaptChange.reduced);
      out.add(AdaptChange.paused);
    } else if (wasPaused && !isPaused) {
      out.add(AdaptChange.resumed);
      if (after == 0) out.add(AdaptChange.restored);
    } else if (before == 0 && after > 0) {
      out.add(AdaptChange.reduced);
    } else if (before > 0 && after == 0) {
      out.add(AdaptChange.restored);
    }
    return out;
  }
}
