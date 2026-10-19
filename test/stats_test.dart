import 'package:catzconnect/src/calls/models.dart';
import 'package:catzconnect/src/calls/stats.dart';
import 'package:flutter_test/flutter_test.dart';

StatsEntry _e(String id, String type, Map<String, dynamic> values) => StatsEntry(id: id, type: type, values: values);

List<StatsEntry> _report({
  required String localType,
  required String remoteType,
  double rtt = 0.05,
  int bytesSent = 1000,
  int bytesReceived = 1000,
  int packetsLost = 0,
  int packetsReceived = 100,
  double jitter = 0.01,
  bool useTransport = true,
}) {
  return <StatsEntry>[
    if (useTransport) _e('T1', 'transport', <String, dynamic>{'selectedCandidatePairId': 'CP1'}),
    _e('CP0', 'candidate-pair', <String, dynamic>{
      'localCandidateId': 'L0',
      'remoteCandidateId': 'R0',
      'state': 'failed',
      'nominated': false,
    }),
    _e('CP1', 'candidate-pair', <String, dynamic>{
      'localCandidateId': 'L1',
      'remoteCandidateId': 'R1',
      'state': 'succeeded',
      'nominated': true,
      'currentRoundTripTime': rtt,
      'bytesSent': bytesSent,
      'bytesReceived': bytesReceived,
    }),
    _e('L0', 'local-candidate', <String, dynamic>{'candidateType': 'relay'}),
    _e('R0', 'remote-candidate', <String, dynamic>{'candidateType': 'relay'}),
    _e('L1', 'local-candidate', <String, dynamic>{'candidateType': localType}),
    _e('R1', 'remote-candidate', <String, dynamic>{'candidateType': remoteType}),
    _e('IA', 'inbound-rtp', <String, dynamic>{
      'kind': 'audio',
      'jitter': jitter,
      'packetsLost': packetsLost,
      'packetsReceived': packetsReceived,
    }),
  ];
}

void main() {
  test('direct when both candidates are host/srflx', () {
    expect(detectConnectionType(_report(localType: 'host', remoteType: 'srflx')), ConnectionType.direct);
    expect(detectConnectionType(_report(localType: 'prflx', remoteType: 'host')), ConnectionType.direct);
  });

  test('relay when either side is a TURN relay', () {
    expect(detectConnectionType(_report(localType: 'relay', remoteType: 'host')), ConnectionType.relay);
    expect(detectConnectionType(_report(localType: 'srflx', remoteType: 'relay')), ConnectionType.relay);
  });

  test('falls back to the nominated succeeded pair without transport stats', () {
    final List<StatsEntry> r = _report(localType: 'relay', remoteType: 'srflx', useTransport: false);
    expect(selectedCandidatePair(r)?.id, 'CP1');
    expect(detectConnectionType(r), ConnectionType.relay);
  });

  test('legacy selected flag', () {
    final List<StatsEntry> r = <StatsEntry>[
      _e('P', 'candidate-pair', <String, dynamic>{'selected': true, 'localCandidateId': 'L', 'remoteCandidateId': 'R'}),
      _e('L', 'local-candidate', <String, dynamic>{'candidateType': 'host'}),
      _e('R', 'remote-candidate', <String, dynamic>{'candidateType': 'host'}),
    ];
    expect(detectConnectionType(r), ConnectionType.direct);
  });

  test('no pair yet', () {
    expect(detectConnectionType(<StatsEntry>[]), isNull);
    expect(selectedCandidatePair(<StatsEntry>[_e('x', 'codec', <String, dynamic>{})]), isNull);
  });

  test('values given as strings (native platforms) are parsed', () {
    final List<StatsEntry> r = <StatsEntry>[
      _e('T', 'transport', <String, dynamic>{'selectedCandidatePairId': 'P'}),
      _e('P', 'candidate-pair', <String, dynamic>{
        'localCandidateId': 'L',
        'remoteCandidateId': 'R',
        'currentRoundTripTime': '0.120',
        'bytesSent': '5000',
        'bytesReceived': '5000',
      }),
      _e('L', 'local-candidate', <String, dynamic>{'candidateType': 'relay'}),
      _e('R', 'remote-candidate', <String, dynamic>{'candidateType': 'host'}),
    ];
    final StatsSample s = StatsAccumulator().add(r, DateTime(2026));
    expect(s.connection, ConnectionType.relay);
    expect(s.rttMs, closeTo(120, 0.001));
  });

  test('accumulator computes rtt, jitter, interval loss and bitrate', () {
    final StatsAccumulator acc = StatsAccumulator();
    final DateTime t0 = DateTime(2026, 10, 18, 12);
    final StatsSample first = acc.add(
      _report(localType: 'host', remoteType: 'host', bytesSent: 0, bytesReceived: 0, packetsReceived: 100),
      t0,
    );
    expect(first.rttMs, closeTo(50, 0.001));
    expect(first.jitterMs, closeTo(10, 0.001));
    expect(first.lossPct, 0);
    expect(first.bitrateKbps, isNull, reason: 'needs two samples');
    expect(first.level, QualityLevel.good);

    final StatsSample second = acc.add(
      _report(
        localType: 'host',
        remoteType: 'host',
        rtt: 0.4,
        bytesSent: 62500,
        bytesReceived: 62500,
        packetsLost: 5,
        packetsReceived: 195,
      ),
      t0.add(const Duration(seconds: 10)),
    );
    // 125 000 bytes in 10 s = 100 kbit/s
    expect(second.bitrateKbps, closeTo(100, 0.001));
    // interval: 5 lost, 95 received -> 5 %
    expect(second.lossPct, closeTo(5, 0.001));
    expect(second.rttMs, closeTo(400, 0.001));
    expect(second.level, QualityLevel.fair);
  });

  test('quality levels match the browser SDK', () {
    expect(qualityLevel(), QualityLevel.unknown);
    expect(qualityLevel(rttMs: 100, lossPct: 0.5), QualityLevel.good);
    expect(qualityLevel(rttMs: 299, lossPct: 2.9), QualityLevel.good);
    expect(qualityLevel(rttMs: 300, lossPct: 0), QualityLevel.fair);
    expect(qualityLevel(rttMs: 100, lossPct: 5), QualityLevel.fair);
    expect(qualityLevel(rttMs: 601), QualityLevel.poor);
    expect(qualityLevel(lossPct: 11), QualityLevel.poor);
  });

  test('summary for the stats frame', () {
    final StatsSummary? sum = StatsSummary.from(const <StatsSample>[
      StatsSample(connection: ConnectionType.direct, rttMs: 40, jitterMs: 10, lossPct: 1, bitrateKbps: 300),
      StatsSample(connection: ConnectionType.relay, rttMs: 80, jitterMs: 20, lossPct: 4, bitrateKbps: 200),
    ]);
    expect(sum, isNotNull);
    expect(sum!.connection, ConnectionType.relay);
    expect(sum.rttMs, closeTo(60, 0.001));
    expect(sum.jitterMs, closeTo(15, 0.001));
    expect(sum.lossPct, 4);
    expect(sum.bitrateKbps, closeTo(500, 0.001));
    expect(StatsSummary.from(const <StatsSample>[]), isNull);
  });
}
