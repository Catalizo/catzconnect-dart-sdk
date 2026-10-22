// Pure-Dart interpretation of WebRTC stats reports (standard `RTCStats`
// shape: id, type, values). The WebRTC layer converts flutter_webrtc's
// `StatsReport` into [StatsEntry] and feeds it here.

import 'models.dart';

/// One entry of a `getStats()` result.
class StatsEntry {
  const StatsEntry({required this.id, required this.type, required this.values});

  final String id;
  final String type;
  final Map<String, dynamic> values;

  Object? operator [](String key) => values[key];
}

/// Metrics for one peer at one point in time.
class StatsSample {
  const StatsSample({
    this.connection,
    this.localCandidateType,
    this.remoteCandidateType,
    this.rttMs,
    this.jitterMs,
    this.lossPct,
    this.bitrateKbps,
    this.availableOutgoingKbps,
    this.remoteLossPct,
    this.cpuLimited = false,
  });

  final ConnectionType? connection;
  final String? localCandidateType;
  final String? remoteCandidateType;
  final double? rttMs;
  final double? jitterMs;
  final double? lossPct;
  final double? bitrateKbps;

  /// `availableOutgoingBitrate` of the selected pair (kbps), when reported.
  final double? availableOutgoingKbps;

  /// Loss of what this side sends, from the peer's receiver reports
  /// (`remote-inbound-rtp` fractionLost, %).
  final double? remoteLossPct;

  /// An outbound video stream is limited by CPU
  /// (`qualityLimitationReason: cpu`).
  final bool cpuLimited;

  QualityLevel get level => qualityLevel(rttMs: rttMs, lossPct: lossPct);
}

/// good: rtt < 300 ms and loss < 3 %; poor: rtt > 600 ms or loss > 10 %;
/// otherwise fair. Unknown when neither is known. (Same grading as the
/// browser SDK.)
QualityLevel qualityLevel({double? rttMs, double? lossPct}) {
  if (rttMs == null && lossPct == null) return QualityLevel.unknown;
  final double rtt = rttMs ?? 0.0;
  final double loss = lossPct ?? 0.0;
  if (rtt > 600 || loss > 10) return QualityLevel.poor;
  if (rtt < 300 && loss < 3) return QualityLevel.good;
  return QualityLevel.fair;
}

/// Finds the candidate pair currently used for media.
StatsEntry? selectedCandidatePair(List<StatsEntry> entries) {
  final Map<String, StatsEntry> byId = <String, StatsEntry>{for (final StatsEntry e in entries) e.id: e};
  // 1. Standard: transport.selectedCandidatePairId
  for (final StatsEntry e in entries) {
    if (e.type != 'transport') continue;
    final String? id = asString(e['selectedCandidatePairId']);
    if (id != null) {
      final StatsEntry? pair = byId[id];
      if (pair != null) return pair;
    }
  }
  final List<StatsEntry> pairs = entries.where((StatsEntry e) => e.type == 'candidate-pair').toList();
  // 2. Legacy/Firefox: selected == true
  for (final StatsEntry p in pairs) {
    if (asBool(p['selected']) == true) return p;
  }
  // 3. Nominated + succeeded, preferring the one that moved the most bytes.
  StatsEntry? best;
  double bestBytes = -1;
  for (final StatsEntry p in pairs) {
    if (asBool(p['nominated']) != true) continue;
    if (asString(p['state']) != 'succeeded') continue;
    final double bytes = (asDouble(p['bytesSent']) ?? 0.0) + (asDouble(p['bytesReceived']) ?? 0.0);
    if (bytes > bestBytes) {
      best = p;
      bestBytes = bytes;
    }
  }
  return best;
}

bool _isRelayType(String? t) => t == 'relay' || t == 'relayed';

/// Connection type of the selected pair: `relay` when either end is a TURN
/// relay candidate, otherwise `direct`. Null when no pair is selected yet.
ConnectionType? detectConnectionType(List<StatsEntry> entries) {
  final StatsEntry? pair = selectedCandidatePair(entries);
  if (pair == null) return null;
  final _CandidateTypes types = _candidateTypes(entries, pair);
  if (types.local == null && types.remote == null) return null;
  return (_isRelayType(types.local) || _isRelayType(types.remote))
      ? ConnectionType.relay
      : ConnectionType.direct;
}

class _CandidateTypes {
  const _CandidateTypes(this.local, this.remote);
  final String? local;
  final String? remote;
}

_CandidateTypes _candidateTypes(List<StatsEntry> entries, StatsEntry pair) {
  final String? localId = asString(pair['localCandidateId']);
  final String? remoteId = asString(pair['remoteCandidateId']);
  String? local;
  String? remote;
  for (final StatsEntry e in entries) {
    if (localId != null && e.id == localId) local = asString(e['candidateType']);
    if (remoteId != null && e.id == remoteId) remote = asString(e['candidateType']);
  }
  return _CandidateTypes(local, remote);
}

/// Turns successive stats reports for ONE peer into samples (loss and
/// bitrate are computed from the difference to the previous report).
class StatsAccumulator {
  double? _prevBytes;
  DateTime? _prevAt;
  double? _prevLost;
  double? _prevReceived;

  void reset() {
    _prevBytes = null;
    _prevAt = null;
    _prevLost = null;
    _prevReceived = null;
  }

  StatsSample add(List<StatsEntry> entries, DateTime now) {
    final StatsEntry? pair = selectedCandidatePair(entries);
    ConnectionType? connection;
    String? localType;
    String? remoteType;
    double? rttMs;
    if (pair != null) {
      final _CandidateTypes types = _candidateTypes(entries, pair);
      localType = types.local;
      remoteType = types.remote;
      if (localType != null || remoteType != null) {
        connection = (_isRelayType(localType) || _isRelayType(remoteType))
            ? ConnectionType.relay
            : ConnectionType.direct;
      }
      final double? rtt = asDouble(pair['currentRoundTripTime']);
      if (rtt != null) rttMs = rtt * 1000.0;
    }
    double? availableKbps;
    if (pair != null) {
      final double? aob = asDouble(pair['availableOutgoingBitrate']);
      if (aob != null && aob >= 0) availableKbps = aob / 1000.0;
    }
    bool cpuLimited = false;
    double remoteLossSum = 0;
    int remoteLossCount = 0;

    double jitterSum = 0.0;
    int jitterCount = 0;
    double lost = 0;
    double received = 0;
    bool sawInbound = false;
    double rtpBytes = 0;
    bool sawRtpBytes = false;
    double? remoteRtt;
    for (final StatsEntry e in entries) {
      if (e.type == 'inbound-rtp') {
        sawInbound = true;
        final double? j = asDouble(e['jitter']);
        if (j != null) {
          jitterSum += j * 1000.0;
          jitterCount++;
        }
        final double l = asDouble(e['packetsLost']) ?? 0.0;
        if (l > 0) lost += l;
        received += asDouble(e['packetsReceived']) ?? 0.0;
        final double? b = asDouble(e['bytesReceived']);
        if (b != null) {
          rtpBytes += b;
          sawRtpBytes = true;
        }
      } else if (e.type == 'outbound-rtp') {
        final double? b = asDouble(e['bytesSent']);
        if (b != null) {
          rtpBytes += b;
          sawRtpBytes = true;
        }
        final String? kind = asString(e['kind']) ?? asString(e['mediaType']);
        if (kind == 'video' && asString(e['qualityLimitationReason']) == 'cpu') cpuLimited = true;
      } else if (e.type == 'remote-inbound-rtp') {
        final double? r = asDouble(e['roundTripTime']);
        if (r != null) remoteRtt = r * 1000.0;
        final double? fl = asDouble(e['fractionLost']);
        if (fl != null && fl >= 0) {
          remoteLossSum += fl;
          remoteLossCount++;
        }
      }
    }
    rttMs ??= remoteRtt;

    double? lossPct;
    if (sawInbound) {
      double dLost = lost;
      double dRecv = received;
      final double? pl = _prevLost;
      final double? pr = _prevReceived;
      if (pl != null && pr != null && lost >= pl && received >= pr) {
        dLost = lost - pl;
        dRecv = received - pr;
      }
      final double total = dLost + dRecv;
      lossPct = total > 0 ? (dLost / total) * 100.0 : 0.0;
      _prevLost = lost;
      _prevReceived = received;
    }

    double? bytes;
    if (pair != null) {
      final double? s = asDouble(pair['bytesSent']);
      final double? r = asDouble(pair['bytesReceived']);
      if (s != null || r != null) bytes = (s ?? 0.0) + (r ?? 0.0);
    }
    if (bytes == null && sawRtpBytes) bytes = rtpBytes;

    double? kbps;
    final double? pb = _prevBytes;
    final DateTime? pa = _prevAt;
    if (bytes != null && pb != null && pa != null && bytes >= pb) {
      final int ms = now.difference(pa).inMilliseconds;
      if (ms > 0) kbps = (bytes - pb) * 8.0 / ms; // bits per ms == kbit/s
    }
    if (bytes != null) {
      _prevBytes = bytes;
      _prevAt = now;
    }

    return StatsSample(
      connection: connection,
      localCandidateType: localType,
      remoteCandidateType: remoteType,
      rttMs: rttMs,
      jitterMs: jitterCount > 0 ? jitterSum / jitterCount : null,
      lossPct: lossPct,
      bitrateKbps: kbps,
      availableOutgoingKbps: availableKbps,
      remoteLossPct: remoteLossCount > 0 ? (remoteLossSum / remoteLossCount) * 100.0 : null,
      cpuLimited: cpuLimited,
    );
  }
}

/// Call-level figures for the `stats` message, from per-peer samples:
/// relay if any peer is relayed; average rtt and jitter; worst loss; total
/// bitrate. Null when there is nothing to report.
class StatsSummary {
  const StatsSummary({
    required this.connection,
    this.rttMs,
    this.jitterMs,
    this.lossPct,
    this.bitrateKbps,
  });

  final ConnectionType connection;
  final double? rttMs;
  final double? jitterMs;
  final double? lossPct;
  final double? bitrateKbps;

  static StatsSummary? from(Iterable<StatsSample> samples) {
    final List<StatsSample> list = samples.toList();
    if (list.isEmpty) return null;
    bool anyRelay = false;
    bool anyKnown = false;
    final List<double> rtts = <double>[];
    final List<double> jitters = <double>[];
    double? worstLoss;
    double? totalKbps;
    for (final StatsSample s in list) {
      if (s.connection != null) anyKnown = true;
      if (s.connection == ConnectionType.relay) anyRelay = true;
      final double? r = s.rttMs;
      if (r != null) rtts.add(r);
      final double? j = s.jitterMs;
      if (j != null) jitters.add(j);
      final double? l = s.lossPct;
      if (l != null) worstLoss = worstLoss == null ? l : (l > worstLoss ? l : worstLoss);
      final double? k = s.bitrateKbps;
      if (k != null) totalKbps = (totalKbps ?? 0.0) + k;
    }
    if (!anyKnown && rtts.isEmpty && jitters.isEmpty && worstLoss == null && totalKbps == null) {
      return null;
    }
    double? avg(List<double> v) => v.isEmpty ? null : v.reduce((double a, double b) => a + b) / v.length;
    return StatsSummary(
      connection: anyRelay ? ConnectionType.relay : ConnectionType.direct,
      rttMs: avg(rtts),
      jitterMs: avg(jitters),
      lossPct: worstLoss,
      bitrateKbps: totalKbps,
    );
  }
}
