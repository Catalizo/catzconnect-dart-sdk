import 'package:catzconnect/src/calls/models.dart';
import 'package:catzconnect/src/calls/protocol.dart';
import 'package:catzconnect/src/calls/stats.dart';
import 'package:catzconnect/src/calls/warnings.dart';
import 'package:flutter_test/flutter_test.dart';

final DateTime t0 = DateTime.utc(2026, 1, 1);
DateTime at(int ms) => t0.add(Duration(milliseconds: ms));

void main() {
  group('server frames', () {
    test('warning / warning_cleared decode to their own messages', () {
      final ServerMessage w = ServerMessage.decode(
          '{"t":"warning","call_id":"c1","code":"large_call","participants":6,"message":"Many people"}');
      expect(w, isA<WarningMessage>());
      final WarningMessage wm = w as WarningMessage;
      expect(wm.callId, 'c1');
      expect(wm.code, 'large_call');
      expect(wm.participants, 6);
      expect(wm.message, 'Many people');

      final ServerMessage c = ServerMessage.decode('{"t":"warning_cleared","call_id":"c1","code":"large_call"}');
      expect(c, isA<WarningClearedMessage>());
      expect((c as WarningClearedMessage).code, 'large_call');
    });

    test('parseWarning: known code, default English text, unknown code passed through', () {
      final CallWarning? w = parseWarning(
          <String, dynamic>{'t': 'warning', 'call_id': 'c1', 'code': 'large_call', 'participants': 7}, t0);
      expect(w, isNotNull);
      expect(w!.code, CallWarningCodes.largeCall);
      expect(w.message, 'Call quality may drop — many people are in this call');
      expect(w.participants, 7);
      expect(w.source, CallWarningSource.server);
      expect(w.severity, CallWarningSeverity.warning);
      expect(w.at, t0);

      final CallWarning? r =
          parseWarning(<String, dynamic>{'t': 'warning', 'call_id': 'c1', 'code': 'relay_unavailable'}, t0);
      expect(r!.message, "Calls aren't available on this network right now");
      expect(r.participants, isNull);

      final CallWarning? u =
          parseWarning(<String, dynamic>{'t': 'warning', 'call_id': 'c1', 'code': 'future_code', 'participants': '3'}, t0);
      expect(u!.code, 'future_code');
      expect(u.participants, 3);
      expect(u.message, contains('future_code'));

      expect(parseWarning(<String, dynamic>{'t': 'warning', 'code': 'relay_busy'}, t0, fallbackCallId: 'cX')!.callId,
          'cX');
      expect(parseWarning(<String, dynamic>{'t': 'warning', 'code': 'relay_busy'}, t0), isNull);
      expect(parseWarning(<String, dynamic>{'t': 'warning', 'call_id': 'c1'}, t0), isNull);
      expect(parseWarning(<String, dynamic>{'t': 'state', 'call_id': 'c1', 'code': 'x'}, t0), isNull);
      expect(warningSeverity(CallWarningCodes.videoReduced), CallWarningSeverity.info);
    });

    test('parseWarningCleared', () {
      final CallWarningCleared? c =
          parseWarningCleared(<String, dynamic>{'t': 'warning_cleared', 'call_id': 'c1', 'code': 'large_call'}, t0);
      expect(c!.code, 'large_call');
      expect(c.callId, 'c1');
      expect(c.source, CallWarningSource.server);
      expect(parseWarningCleared(<String, dynamic>{'t': 'warning_cleared', 'code': ''}, t0, fallbackCallId: 'c1'),
          isNull);
    });
  });

  test('SustainedFlag: enters after 6 s bad, exits after 6 s good, once each, a blip resets', () {
    final SustainedFlag f = SustainedFlag();
    expect(f.update(true, at(0)), isNull);
    expect(f.update(true, at(2000)), isNull);
    expect(f.update(false, at(4000)), isNull);
    expect(f.update(true, at(6000)), isNull);
    expect(f.update(true, at(10000)), isNull);
    expect(f.update(true, at(12000)), FlagChange.enter);
    expect(f.update(true, at(14000)), isNull);
    expect(f.update(false, at(16000)), isNull);
    expect(f.update(true, at(18000)), isNull);
    expect(f.update(false, at(20000)), isNull);
    expect(f.update(false, at(26000)), FlagChange.exit);
    expect(f.update(false, at(30000)), isNull);
    expect(f.active, isFalse);
  });

  test('networkBad: enter thresholds and stricter exit thresholds', () {
    bool bad({double? avail, double need = 0, double? loss = 0, double? rtt = 100, bool active = false}) =>
        networkBad(availableKbps: avail, neededKbps: need, lossPct: loss, rttMs: rtt, active: active);
    expect(bad(loss: 8.5), isTrue);
    expect(bad(loss: 8), isFalse);
    expect(bad(rtt: 650), isTrue);
    expect(bad(avail: 300, need: 380), isTrue);
    expect(bad(avail: 400, need: 380), isFalse);
    expect(bad(loss: 6, active: true), isTrue);
    expect(bad(rtt: 500, active: true), isTrue);
    expect(bad(avail: 418, need: 380, active: true), isTrue);
    expect(bad(loss: 3, rtt: 300, avail: 460, need: 380, active: true), isFalse);
    expect(bad(loss: null, rtt: null, need: 380), isFalse);
    expect(requiredKbps(4, sendingVideo: true), 760);
    expect(requiredKbps(4, sendingVideo: false), 160);
  });

  test('videoBudget: clamp(available / peers, 150, 1500) and resolution steps', () {
    final VideoBudget a = videoBudget(20000, 2);
    expect(a.maxBitrateKbps, 1500);
    expect(a.scaleResolutionDownBy, 1);
    expect(a.paused, isFalse);
    final VideoBudget b = videoBudget(4400, 4);
    expect(b.maxBitrateKbps, 1100);
    expect(b.level, 1);
    expect(videoBudget(3000, 4).scaleResolutionDownBy, 1.5);
    expect(videoBudget(3000, 4).maxBitrateKbps, 750);
    expect(videoBudget(2000, 5).scaleResolutionDownBy, 2);
    expect(videoBudget(1000, 5).scaleResolutionDownBy, 3);
    final VideoBudget p = videoBudget(1000, 8);
    expect(p.paused, isTrue);
    expect(p.maxBitrateKbps, 150);
    expect(levelFor(150), 4);
    expect(levelFor(149.9), kVideoPaused);
    expect(levelFor(double.nan), kVideoPaused);

    expect(videoTarget(0, 1).isDefault, isTrue);
    expect(videoTarget(0, 3), const VideoTarget(level: 0, maxBitrateKbps: 1500, scaleResolutionDownBy: 1, active: true));
    expect(videoTarget(kVideoPaused, 3),
        const VideoTarget(level: kVideoPaused, maxBitrateKbps: 150, scaleResolutionDownBy: 3, active: false));
  });

  group('VideoAdapter', () {
    test('warmup, step down after 4 s, hysteresis keeps a level, step up one at a time', () {
      final VideoAdapter a = VideoAdapter();
      List<AdaptChange> s(int ms, double avail, {int peers = 4, double loss = 0}) =>
          a.update(now: at(ms), peers: peers, availableKbps: avail, lossPct: loss, rttMs: 100);
      expect(s(0, 1000), isEmpty);
      expect(s(8000, 1000), isEmpty);
      expect(a.level, 0);
      expect(s(10000, 2400), isEmpty);
      expect(s(12000, 2400), isEmpty);
      expect(s(14000, 2400), <AdaptChange>[AdaptChange.reduced]);
      expect(a.level, 2);
      for (int t = 16000; t <= 30000; t += 2000) {
        expect(s(t, 2000), isEmpty);
      }
      expect(a.level, 2);
      for (int t = 32000; t <= 42000; t += 2000) {
        expect(s(t, 2100), isEmpty);
      }
      expect(a.level, 1);
      for (int t = 44000; t <= 70000; t += 2000) {
        s(t, 4000, loss: 5);
      }
      expect(a.level, 1);
      for (int t = 72000; t <= 82000; t += 2000) {
        s(t, 4000);
      }
      expect(a.level, 0);
    });

    test('pause under 150 kbps per peer, retry with backoff, resume', () {
      final VideoAdapter a = VideoAdapter(warmup: Duration.zero);
      List<AdaptChange> s(int ms, double avail) =>
          a.update(now: at(ms), peers: 3, availableKbps: avail, lossPct: 0, rttMs: 100);
      expect(s(0, 300), isEmpty);
      expect(s(4000, 300), <AdaptChange>[AdaptChange.reduced, AdaptChange.paused]);
      expect(a.paused, isTrue);
      expect(s(10000, 300), isEmpty);
      expect(s(19000, 300), <AdaptChange>[AdaptChange.resumed]);
      expect(a.level, 4);
      expect(s(21000, 300), isEmpty);
      expect(s(25000, 300), <AdaptChange>[AdaptChange.paused]);
      expect(s(50000, 300), isEmpty);
      expect(s(55000, 3000), <AdaptChange>[AdaptChange.resumed]);
      for (int t = 57000; t <= 200000; t += 2000) {
        s(t, 6000);
      }
      expect(a.level, 0);
      expect(a.reduced, isFalse);
    });

    test('one peer only pauses and comes back to the platform limits', () {
      final VideoAdapter a = VideoAdapter(warmup: Duration.zero);
      List<AdaptChange> s(int ms, double avail) =>
          a.update(now: at(ms), peers: 1, availableKbps: avail, lossPct: 0, rttMs: 50);
      for (int t = 0; t <= 20000; t += 2000) {
        expect(s(t, 400), isEmpty);
      }
      expect(a.level, 0);
      s(22000, 100);
      expect(s(26000, 100), <AdaptChange>[AdaptChange.reduced, AdaptChange.paused]);
      expect(s(41000, 100), <AdaptChange>[AdaptChange.resumed, AdaptChange.restored]);
      expect(a.level, 0);
    });
  });

  test('StatsAccumulator: availableOutgoingBitrate, remote loss, CPU limitation', () {
    final StatsSample s = StatsAccumulator().add(<StatsEntry>[
      const StatsEntry(id: 'T', type: 'transport', values: <String, dynamic>{'selectedCandidatePairId': 'CP'}),
      const StatsEntry(id: 'CP', type: 'candidate-pair', values: <String, dynamic>{
        'localCandidateId': 'L',
        'remoteCandidateId': 'R',
        'availableOutgoingBitrate': 850000,
      }),
      const StatsEntry(id: 'L', type: 'local-candidate', values: <String, dynamic>{'candidateType': 'host'}),
      const StatsEntry(id: 'R', type: 'remote-candidate', values: <String, dynamic>{'candidateType': 'srflx'}),
      const StatsEntry(
          id: 'O', type: 'outbound-rtp', values: <String, dynamic>{'kind': 'video', 'qualityLimitationReason': 'cpu'}),
      const StatsEntry(
          id: 'RI', type: 'remote-inbound-rtp', values: <String, dynamic>{'fractionLost': 0.1, 'roundTripTime': 0.25}),
    ], t0);
    expect(s.connection, ConnectionType.direct);
    expect(s.availableOutgoingKbps, 850);
    expect(s.remoteLossPct, closeTo(10, 0.001));
    expect(s.cpuLimited, isTrue);
    expect(s.rttMs, 250);
  });
}
