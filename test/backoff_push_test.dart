import 'dart:convert';
import 'dart:math' as math;

import 'package:catzconnect/src/calls/backoff.dart';
import 'package:catzconnect/src/calls/models.dart';
import 'package:catzconnect/src/calls/push.dart';
import 'package:flutter_test/flutter_test.dart';

/// Random that always returns the same value.
class _FixedRandom implements math.Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  int nextInt(int max) => (value * max).floor();

  @override
  bool nextBool() => value >= 0.5;
}

void main() {
  group('Backoff', () {
    test('base delay doubles and is capped', () {
      final Backoff b = Backoff();
      expect(b.baseDelayFor(0), const Duration(milliseconds: 500));
      expect(b.baseDelayFor(1), const Duration(milliseconds: 1000));
      expect(b.baseDelayFor(2), const Duration(milliseconds: 2000));
      expect(b.baseDelayFor(4), const Duration(milliseconds: 8000));
      expect(b.baseDelayFor(5), const Duration(seconds: 15));
      expect(b.baseDelayFor(50), const Duration(seconds: 15));
    });

    test('jitter keeps the delay within [d/2, d]', () {
      final Backoff low = Backoff(random: _FixedRandom(0.999999));
      final Backoff high = Backoff(random: _FixedRandom(0.0));
      for (int i = 0; i < 8; i++) {
        final Duration d = low.baseDelayFor(i);
        final Duration a = low.next();
        final Duration c = high.next();
        expect(c, d, reason: 'random 0 gives the full delay');
        expect(a.inMilliseconds, greaterThanOrEqualTo((d.inMilliseconds / 2).floor()));
        expect(a.inMilliseconds, lessThanOrEqualTo(d.inMilliseconds));
      }
    });

    test('random spread stays in range', () {
      final Backoff b = Backoff(random: math.Random(42));
      for (int i = 0; i < 40; i++) {
        final Duration base = b.baseDelayFor(b.attempt);
        final Duration d = b.next();
        expect(d.inMilliseconds, inInclusiveRange((base.inMilliseconds / 2).floor(), base.inMilliseconds));
        expect(d, lessThanOrEqualTo(const Duration(seconds: 15)));
      }
    });

    test('reset starts over and attempt counts', () {
      final Backoff b = Backoff(random: _FixedRandom(0.0));
      expect(b.attempt, 0);
      b.next();
      b.next();
      expect(b.attempt, 2);
      expect(b.next(), const Duration(milliseconds: 2000));
      b.reset();
      expect(b.attempt, 0);
      expect(b.next(), const Duration(milliseconds: 500));
    });

    test('custom settings', () {
      final Backoff b = Backoff(
        initialDelay: const Duration(seconds: 1),
        maxDelay: const Duration(seconds: 3),
        jitter: 0.0,
      );
      expect(b.next(), const Duration(seconds: 1));
      expect(b.next(), const Duration(seconds: 2));
      expect(b.next(), const Duration(seconds: 3));
      expect(b.next(), const Duration(seconds: 3));
    });
  });

  group('push payloads', () {
    test('parses a ringing push (FCM string values)', () {
      final IncomingCall? call = CatzCalls.incomingFromPush(<String, dynamic>{
        'catz_type': 'call',
        'call_id': '7d1f0c62-0000-4000-8000-000000000001',
        'from': 'alice',
        'mode': 'video',
        'engine': 'catz',
      });
      expect(call, isNotNull);
      expect(call!.callId, '7d1f0c62-0000-4000-8000-000000000001');
      expect(call.from, 'alice');
      expect(call.mode, CallMode.video);
      expect(call.engine, 'catz');
      expect(call.fromPush, isTrue);
      expect(call.call, isNull);
    });

    test('defaults: audio mode, missing engine', () {
      final IncomingCall? call = CatzCalls.incomingFromPush(<String, dynamic>{
        'catz_type': 'call',
        'call_id': 'c1',
        'from': 'bob',
      });
      expect(call?.mode, CallMode.audio);
      expect(call?.engine, isNull);
    });

    test('provider engine is kept for hand-off', () {
      final IncomingCall? call = CatzCalls.incomingFromPush(<String, dynamic>{
        'catz_type': 'call',
        'call_id': 'c1',
        'from': 'bob',
        'mode': 'audio',
        'engine': 'agora',
      });
      expect(call?.engine, 'agora');
    });

    test('ignores other pushes', () {
      expect(CatzCalls.incomingFromPush(null), isNull);
      expect(CatzCalls.incomingFromPush(<String, dynamic>{}), isNull);
      expect(CatzCalls.incomingFromPush(<String, dynamic>{'catz_type': 'message', 'call_id': 'c1'}), isNull);
      expect(CatzCalls.incomingFromPush(<String, dynamic>{'catz_type': 'call'}), isNull,
          reason: 'call_id is required');
      expect(CatzCalls.incomingFromPush(<String, dynamic>{'catz_v': '1', 'catz_sealed': 'xxx'}), isNull);
      expect(CatzCalls.isCallPush(<String, dynamic>{'title': 'hi'}), isFalse);
    });

    test('accepts a nested data object or JSON string', () {
      final IncomingCall? nested = CatzCalls.incomingFromPush(<String, dynamic>{
        'data': <String, dynamic>{'catz_type': 'call', 'call_id': 'c2', 'from': 'x', 'mode': 'video'},
      });
      expect(nested?.callId, 'c2');
      final IncomingCall? fromString = CatzCalls.incomingFromPush(<String, dynamic>{
        'data': jsonEncode(<String, dynamic>{'catz_type': 'call', 'call_id': 'c3', 'from': 'y'}),
      });
      expect(fromString?.callId, 'c3');
      expect(CatzCalls.incomingFromPush(<String, dynamic>{'data': 'not json'}), isNull);
      expect(CatzCalls.isCallPush(<String, dynamic>{'catz_type': 'CALL', 'call_id': 'c4'}), isTrue);
    });
  });
}
