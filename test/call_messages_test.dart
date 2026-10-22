import 'dart:convert';
import 'dart:math';

import 'package:catzconnect/src/calls/messages.dart';
import 'package:catzconnect/src/calls/models.dart' show ConnectionType;
import 'package:catzconnect/src/calls/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

const Map<String, dynamic> _limits = <String, dynamic>{
  'chat_max_chars': 10,
  'data_max_bytes': 40,
  'messages_per_sec': 1,
  'messages_burst': 3,
  'messages_relay': true,
};

void main() {
  group('limits', () {
    test('from hello.limits, defaults otherwise', () {
      final MessageLimits l = MessageLimits.fromJson(_limits);
      expect(l.chatMaxChars, 10);
      expect(l.dataMaxBytes, 40);
      expect(l.perSec, 1);
      expect(l.burst, 3);
      expect(l.relay, isTrue);
      // No messages_relay (a server from before in-call messages): relay off.
      expect(MessageLimits.fromJson(null), const MessageLimits(relay: false));
      expect(MessageLimits.fromJson(<String, dynamic>{'chat_max_chars': 5}).relay, isFalse);
      expect(const MessageLimits().withRelay(false), const MessageLimits(relay: false));
      expect(MessageLimits.fromJson(<String, dynamic>{'messages_per_sec': 9, 'messages_burst': 2}).burst, 9,
          reason: 'burst is at least the rate');
      expect(MessageLimits.fromJson(<String, dynamic>{'messages_relay': false}).relay, isFalse);
    });

    test('hello carries them', () {
      final ServerMessage m = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'hello',
        'you': 'u',
        'ice_servers': <dynamic>[],
        'limits': <String, dynamic>{'max_participants': 4, ..._limits},
      }));
      expect((m as HelloMessage).messageLimits, MessageLimits.fromJson(_limits));
      expect(m.maxParticipants, 4);
    });
  });

  group('caps', () {
    final MessageLimits l = MessageLimits.fromJson(_limits);

    test('chat', () {
      expect(checkChat('hello', l), isNull);
      expect(checkChat('ääääääääää', l), isNull, reason: 'characters, not bytes');
      expect(checkChat('01234567890', l)?.code, 'message_too_large');
      expect(checkChat('   ', l)?.code, 'bad_request');
      expect(checkChat(5, l)?.code, 'bad_request');
      expect(checkChat('a\u0000b', l)?.code, 'bad_request');
      expect(checkChat('a\nb', l), isNull);
    });

    test('data, in UTF-8 bytes of compact JSON', () {
      expect(checkData(<String, dynamic>{'a': 1}, l).error, isNull);
      expect(checkData(null, l).error?.code, 'bad_request');
      expect(checkData(<String, dynamic>{'s': 'e' * 32}, l).error, isNull); // 8 + 32 = 40 bytes
      expect(checkData(<String, dynamic>{'s': 'é' * 17}, l).error?.code, 'message_too_large');
      expect(checkData(Object(), l).error?.code, 'bad_request', reason: 'not JSON');
    });

    test('ids', () {
      expect(isValidMessageId('m-1'), isTrue);
      expect(isValidMessageId('a' * 64), isTrue);
      expect(isValidMessageId('a' * 65), isFalse);
      expect(isValidMessageId('a b'), isFalse);
      expect(isValidMessageId(''), isFalse);
      expect(isValidMessageId(3), isFalse);
      final String id = newMessageId(Random(1), DateTime.fromMillisecondsSinceEpoch(1700000000000));
      expect(isValidMessageId(id), isTrue);
      expect(newMessageId(), isNot(newMessageId()));
    });
  });

  test('rate bucket', () {
    final RateBucket b = RateBucket(const MessageLimits(perSec: 1, burst: 3));
    final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
    expect(<bool>[b.take(t0), b.take(t0), b.take(t0), b.take(t0)], <bool>[true, true, true, false]);
    final DateTime t1 = t0.add(const Duration(seconds: 1));
    expect(b.take(t1), isTrue);
    expect(b.take(t1), isFalse);
    expect(b.take(t1.add(const Duration(hours: 1))), isTrue);
  });

  test('dedup keeps the last max keys', () {
    final Dedup d = Dedup(2);
    expect(d.seen('a'), isFalse);
    expect(d.seen('a'), isTrue);
    d.seen('b');
    d.seen('c');
    expect(d.seen('a'), isFalse, reason: 'evicted');
  });

  test('routes', () {
    MessageRoute r(List<bool> open, {bool force = false, bool relay = true}) =>
        chooseRoute(open, forceServer: force, serverRelay: relay);
    expect(r(<bool>[true, true]), MessageRoute.p2p);
    expect(r(<bool>[true, false]), MessageRoute.relay);
    expect(r(<bool>[]), MessageRoute.relay);
    expect(r(<bool>[true], force: true), MessageRoute.relay);
    expect(r(<bool>[true, false], relay: false), MessageRoute.p2p);
    expect(r(<bool>[false], relay: false), MessageRoute.none);
  });

  test('peer envelope round trip and checks', () {
    final MessageLimits l = MessageLimits.fromJson(_limits);
    final String enc =
        const PeerEnvelope(kind: 'data', id: 'd1', ts: 5, to: 'p1', payload: <int>[1, 2], reliable: false).encode();
    expect(jsonDecode(enc), <String, dynamic>{
      'v': 1,
      'k': 'data',
      'id': 'd1',
      'ts': 5,
      'to': 'p1',
      'payload': <int>[1, 2],
      'reliable': false,
    });
    final PeerEnvelope? e = PeerEnvelope.decode(enc, l);
    expect(e?.kind, 'data');
    expect(e?.payload, <int>[1, 2]);
    expect(e?.reliable, isFalse);
    expect(e?.to, 'p1');
    final PeerEnvelope? c = PeerEnvelope.decode(const PeerEnvelope(kind: 'chat', id: 'c1', ts: 9, text: 'hi').encode(), l);
    expect(c?.text, 'hi');
    expect(c?.to, isNull);
    // The TS SDK's envelope decodes the same.
    expect(PeerEnvelope.decode('{"v":1,"k":"chat","id":"m","ts":1,"to":null,"text":"x"}', l)?.text, 'x');
    expect(PeerEnvelope.decode('nope', l), isNull);
    expect(PeerEnvelope.decode('{"v":2,"k":"chat","id":"m","ts":1,"text":"x"}', l), isNull);
    expect(PeerEnvelope.decode('{"v":1,"k":"chat","id":"bad id","ts":1,"text":"x"}', l), isNull);
    expect(PeerEnvelope.decode('{"v":1,"k":"chat","id":"m","ts":1,"text":"01234567890"}', l), isNull);
    expect(PeerEnvelope.decode(42, l), isNull);
  });

  group('protocol', () {
    test('relayed chat and data frames', () {
      final ServerMessage m = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'chat',
        'call_id': 'c1',
        'id': 'm1',
        'from': 'p2',
        'user_id': 'bob',
        'to': null,
        'text': 'hello',
        'ts': 123,
      }));
      // Kept an UnknownMessage: the sealed ServerMessage set is unchanged.
      expect(m, isA<UnknownMessage>());
      final CallMessageFrame f = CallMessageFrame.tryFrom(m)!;
      expect(f.isChat, isTrue);
      expect((f.callId, f.id, f.from, f.userId, f.to, f.text, f.ts), ('c1', 'm1', 'p2', 'bob', null, 'hello', 123));

      final CallMessageFrame d = CallMessageFrame.tryFrom(ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'data',
        'call_id': 'c1',
        'id': 'd1',
        'from': 'p3',
        'user_id': 'carol',
        'to': 'p1',
        'payload': <String, dynamic>{'x': 1},
        'ts': 5,
      })))!;
      expect(d.isChat, isFalse);
      expect(d.to, 'p1');
      expect(d.payload, <String, dynamic>{'x': 1});
    });

    test('error with a message id', () {
      final ErrorMessage e = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'error',
        'code': 'rate_limited',
        'message': 'Too many messages — slow down',
        'call_id': 'c1',
        'id': 'm4',
      })) as ErrorMessage;
      expect(e.messageId, 'm4');
      expect(e.error.code, 'rate_limited');
      final ErrorMessage plain = ServerMessage.decode(
          jsonEncode(<String, dynamic>{'t': 'error', 'code': 'not_found', 'message': 'x', 'id': null})) as ErrorMessage;
      expect(plain.messageId, isNull);
    });

    test('client frames', () {
      final ClientMessage c = ClientMessage.chat('c1', 'm1', 'hi', to: 'p2');
      expect(c.toJson(), <String, dynamic>{'t': 'chat', 'call_id': 'c1', 'id': 'm1', 'text': 'hi', 'to': 'p2'});
      expect(c.queueable, isTrue);
      final ClientMessage d = ClientMessage.data('c1', 'd1', <int>[1], reliable: false);
      expect(d.toJson(), <String, dynamic>{'t': 'data', 'call_id': 'c1', 'id': 'd1', 'payload': <int>[1]});
      expect(d.queueable, isFalse, reason: 'unreliable data is not sent late');
      expect(ClientMessage.data('c1', 'd2', 1).queueable, isTrue);
      expect(ClientMessage.stats('c1', connection: ConnectionType.direct).queueable, isFalse);
    });
  });

  group('robustness', () {
    test('an out-of-range ts never throws', () {
      const MessageLimits l = MessageLimits();
      final PeerEnvelope? e = PeerEnvelope.decode('{"v":1,"k":"chat","id":"m","ts":1e300,"to":null,"text":"x"}', l);
      expect(e, isNotNull);
      expect(e!.ts, 0);
      expect(epochMsOrNull(9e15), isNull);
      expect(epochMsOrNull(-9e15), isNull);
      expect(epochMsOrNull(1700000000000), 1700000000000);
      expect(epochMsOrNull('1'), isNull);
      final DateTime before = DateTime.now();
      expect(messageTime(null).isBefore(before), isFalse);
      expect(messageTime(8640000000000001).isBefore(before), isFalse, reason: 'local time instead of a RangeError');
      expect(messageTime(1700000000000), DateTime.fromMillisecondsSinceEpoch(1700000000000));
      final CallMessageFrame f = CallMessageFrame.tryFrom(ServerMessage.decode(
          '{"t":"chat","call_id":"c1","id":"m1","from":"p2","text":"x","ts":1e30}'))!;
      expect(f.ts, isNull);
    });

    test('"Unknown message type" refusals are recognised', () {
      expect(isUnsupportedMessageError('bad_request', 'Unknown message type "chat"'), isTrue);
      expect(isUnsupportedMessageError('bad_request', 'Unknown message type "data"'), isTrue);
      expect(isUnsupportedMessageError('bad_request', 'Unknown message type "join"'), isFalse);
      expect(isUnsupportedMessageError('call_full', 'Unknown message type "chat"'), isFalse);
      final ServerMessage m = ServerMessage.decode(
          '{"t":"error","code":"bad_request","message":"Unknown message type \\"chat\\"","call_id":"c1"}');
      expect(m, isA<ErrorMessage>());
      final ErrorMessage err = m as ErrorMessage;
      expect(err.messageId, isNull);
      expect(isUnsupportedMessageError(err.error.code, err.error.message), isTrue);
    });

    test('other unknown frames are not chat frames', () {
      expect(CallMessageFrame.tryFrom(ServerMessage.decode('{"t":"future_thing"}')), isNull);
      expect(CallMessageFrame.tryFrom(ServerMessage.decode('{"t":"pong"}')), isNull);
    });
  });
}
