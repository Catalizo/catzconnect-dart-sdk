// calls.* request bodies and validation against the TypeScript SDK.

import 'dart:convert';

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/host_sodium.dart';

CreateCallInput createInputFromJson(Map<String, dynamic> j) => CreateCallInput(
      mode: CallMode.parse(j['mode']),
      from: j['from'] as String,
      to: (j['to'] as List<Object?>).cast<String>(),
      engine: j['engine'] as String?,
      ring: j['ring'] as bool?,
      metadata: j['metadata'] == null ? null : Map<String, Object?>.from(j['metadata'] as Map<String, dynamic>),
      maxParticipants: j['maxParticipants'] as int?,
    );

void main() {
  final Map<String, dynamic> calls = loadVectors()['calls'] as Map<String, dynamic>;

  test('buildCreateCallPayload', () {
    for (final Object? raw in calls['create_payloads'] as List<Object?>) {
      final Map<String, dynamic> c = raw! as Map<String, dynamic>;
      expect(jsonEncode(buildCreateCallPayload(createInputFromJson(c['input'] as Map<String, dynamic>))),
          c['payload_json']);
    }
  });

  test('buildCreateCallPayload errors', () {
    for (final Object? raw in calls['create_errors'] as List<Object?>) {
      final Map<String, dynamic> c = raw! as Map<String, dynamic>;
      final String error = c['error'] as String;
      expect(
        () => buildCreateCallPayload(createInputFromJson(c['input'] as Map<String, dynamic>)),
        throwsA(isA<CatzValidationException>().having((CatzValidationException e) => e.message, 'message', error)),
      );
    }
  });

  test('buildCallTokenPayload', () {
    for (final Object? raw in calls['token_payloads'] as List<Object?>) {
      final Map<String, dynamic> c = raw! as Map<String, dynamic>;
      final String userId = c['user_id'] as String;
      final int? ttl = c['ttl'] as int?;
      final String? error = c['error'] as String?;
      if (error == null) {
        expect(jsonEncode(buildCallTokenPayload(userId, ttl)), c['payload_json']);
      } else {
        expect(
          () => buildCallTokenPayload(userId, ttl),
          throwsA(isA<CatzValidationException>().having((CatzValidationException e) => e.message, 'message', error)),
        );
      }
    }
  });

  test('Call.fromJson reads participants, provider and timings', () {
    final Call c = Call.fromJson(<String, dynamic>{
      'id': 'c1',
      'engine': 'prov_1',
      'provider': <String, dynamic>{'id': 'prov_1', 'label': 'EU', 'name': 'livekit'},
      'mode': 'audio',
      'status': 'ended',
      'room': 'r',
      'participants': <Object?>[
        <String, dynamic>{'user_id': 'a', 'role': 'caller', 'state': 'left', 'seconds': 61, 'connection': 'provider'},
      ],
      'created_at': '2026-10-18T00:00:00Z',
      'duration_secs': 61,
      'billed_minutes': 2,
      'end_reason': 'hangup',
    });
    expect(c.mode, CallMode.audio);
    expect(c.status, CallStatus.ended);
    expect(c.provider!.name, 'livekit');
    expect(c.participants.single.seconds, 61);
    expect(c.billedMinutes, 2);
  });

  test('CallToken.expiresAtTime', () {
    expect(const CallToken(token: 't', expiresAt: 99, wsUrl: '').expiresAtTime,
        DateTime.fromMillisecondsSinceEpoch(99000, isUtc: true));
    expect(const CallToken(token: 't', expiresAt: '2026-10-18T00:00:00Z', wsUrl: '').expiresAtTime,
        DateTime.utc(2026, 10, 18));
    expect(const CallToken(token: 't', expiresAt: '', wsUrl: '').expiresAtTime, isNull);
  });
}
