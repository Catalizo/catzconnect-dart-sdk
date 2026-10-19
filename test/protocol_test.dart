import 'dart:convert';

import 'package:catzconnect/src/calls/models.dart';
import 'package:catzconnect/src/calls/protocol.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _decodeFrame(String text) => jsonDecode(text) as Map<String, dynamic>;

void main() {
  group('server messages', () {
    test('hello', () {
      final ServerMessage m = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'hello',
        'you': 'user-1',
        'ice_servers': <dynamic>[
          <String, dynamic>{
            'urls': <String>['stun:turn.example.com:3478'],
          },
          <String, dynamic>{
            'urls': <String>['turn:turn.example.com:3478?transport=udp', 'turns:turn.example.com:5349?transport=tcp'],
            'username': '1700000000:call:pid',
            'credential': 'secret',
          },
          <String, dynamic>{'urls': 'stun:single.example.com:3478'},
          <String, dynamic>{'urls': <String>[]},
        ],
        'ice_ttl': 3600,
        'limits': <String, dynamic>{'max_participants': 4},
        'resume': <String, dynamic>{'call_id': 'c1', 'pid': 'p9'},
      }));
      expect(m, isA<HelloMessage>());
      final HelloMessage h = m as HelloMessage;
      expect(h.you, 'user-1');
      expect(h.iceServers.length, 3, reason: 'empty url lists are dropped');
      expect(h.iceServers[1].username, '1700000000:call:pid');
      expect(h.iceServers[1].isTurn, isTrue);
      expect(h.iceServers[0].isTurn, isFalse);
      expect(h.iceServers[2].urls, <String>['stun:single.example.com:3478']);
      expect(h.iceTtl, 3600);
      expect(h.maxParticipants, 4);
      expect(h.resumePidFor('c1'), 'p9');
      expect(h.resumePidFor('other'), isNull);
      expect(h.iceServers[1].toJson(), <String, dynamic>{
        'urls': <String>['turn:turn.example.com:3478?transport=udp', 'turns:turn.example.com:5349?transport=tcp'],
        'username': '1700000000:call:pid',
        'credential': 'secret',
      });
      expect(h.iceServers[0].toJson().containsKey('username'), isFalse);
    });

    test('incoming', () {
      final ServerMessage m = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'incoming',
        'call': <String, dynamic>{
          'id': 'c1',
          'mode': 'video',
          'engine': 'catz',
          'from': 'alice',
          'participants': <dynamic>[
            <String, dynamic>{'user_id': 'alice', 'role': 'caller', 'state': 'joined'},
            <String, dynamic>{'user_id': 'bob', 'role': 'callee', 'state': 'ringing'},
          ],
          'metadata': <String, dynamic>{'topic': 'support'},
        },
      }));
      final IncomingMessage inc = m as IncomingMessage;
      expect(inc.call.id, 'c1');
      expect(inc.call.mode, CallMode.video);
      expect(inc.call.engine, 'catz');
      expect(inc.call.from, 'alice');
      expect(inc.call.participants.length, 2);
      expect(inc.call.participants[1].userId, 'bob');
      expect(inc.call.metadata?['topic'], 'support');
      final IncomingCall ic = IncomingCall.fromCall(inc.call);
      expect(ic.callId, 'c1');
      expect(ic.from, 'alice');
      expect(ic.fromPush, isFalse);
      expect(ic.metadata?['topic'], 'support');
    });

    test('joined with peers, polite_for and pid', () {
      final JoinedMessage j = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'joined',
        'pid': 'p-me',
        'call': <String, dynamic>{'id': 'c1', 'mode': 'audio', 'engine': 'catz', 'status': 'ringing'},
        'peers': <dynamic>[
          <String, dynamic>{'pid': 'p-a', 'user_id': 'alice'},
          <String, dynamic>{'pid': '', 'user_id': 'ghost'},
        ],
        'polite_for': <String, dynamic>{'p-a': true},
      })) as JoinedMessage;
      expect(j.pid, 'p-me');
      expect(j.call.status, CallStatus.ringing);
      expect(j.peers.length, 1, reason: 'peers without pid are ignored');
      expect(j.peers.first.userId, 'alice');
      expect(j.politeFor, <String, bool>{'p-a': true});
      expect(j.provider, isNull);
    });

    test('joined reads the own pid from you.pid / call.pid', () {
      final JoinedMessage a = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'joined',
        'you': <String, dynamic>{'pid': 'p1'},
        'call': <String, dynamic>{'id': 'c'},
        'peers': <dynamic>[],
      })) as JoinedMessage;
      expect(a.pid, 'p1');
      final JoinedMessage b = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'joined',
        'call': <String, dynamic>{'id': 'c', 'pid': 'p2'},
      })) as JoinedMessage;
      expect(b.pid, 'p2');
      expect(b.peers, isEmpty);
    });

    test('server shapes: hello STUN-only + resume_all, joined ice_servers, ice_refresh call_id, pong', () {
      final HelloMessage h = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'hello',
        'you': 'bob',
        'ice_servers': <dynamic>[
          <String, dynamic>{'urls': <String>['stun:t:3478']},
        ],
        'ice_ttl': 3600,
        'limits': <String, dynamic>{'max_participants': 4, 'max_frame_bytes': 65536},
        'resume_all': <dynamic>[
          <String, dynamic>{'call_id': 'c1', 'pid': 'p1'},
          <String, dynamic>{'call_id': 'c2', 'pid': 'p2'},
        ],
        'resume': <String, dynamic>{'call_id': 'c1', 'pid': 'p1'},
      })) as HelloMessage;
      expect(h.you, 'bob');
      expect(h.resumePidFor('c2'), 'p2');
      expect(h.resumeAll.length, 2);
      final JoinedMessage j = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'joined',
        'call': <String, dynamic>{'id': 'c1', 'mode': 'audio', 'engine': 'catz'},
        'pid': 'p1',
        'peers': <dynamic>[],
        'polite_for': <String, dynamic>{},
        'resume': true,
        'ice_servers': <dynamic>[
          <String, dynamic>{'urls': <String>['turn:t:3478?transport=udp'], 'username': 'u', 'credential': 'c'},
        ],
        'ice_ttl': 3600,
      })) as JoinedMessage;
      expect(j.resume, isTrue);
      expect(j.iceServers!.single.username, 'u');
      expect(j.iceTtl, 3600);
      final JoinedMessage noIce = ServerMessage.decode('{"t":"joined","call":{"id":"c"},"peers":[]}') as JoinedMessage;
      expect(noIce.iceServers, isNull);
      expect(noIce.resume, isFalse);
      final IceRefreshMessage r = ServerMessage.decode(
          '{"t":"ice_refresh","call_id":"c1","ice_servers":[{"urls":["turn:h:3478"]}],"ice_ttl":60}') as IceRefreshMessage;
      expect(r.callId, 'c1');
      expect(r.iceTtl, 60);
      expect(ServerMessage.decode('{"t":"pong","ts":1}'), isA<PongMessage>());
      expect(_decodeFrame(ClientMessage.join('c', audio: true, video: false, platform: 'android').encode())['platform'],
          'android');
      expect(_decodeFrame(ClientMessage.accept('c', audio: true, video: true).encode())['media'],
          <String, dynamic>{'audio': true, 'video': true});
    });

    test('joined with provider hand-off', () {
      final JoinedMessage j = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'joined',
        'call': <String, dynamic>{'id': 'c2', 'mode': 'video', 'engine': 'agora'},
        'peers': <dynamic>[],
        'polite_for': <String, dynamic>{},
        'provider': <String, dynamic>{
          'name': 'agora',
          'room': 'room-1',
          'token': 'tok',
          'app_id': 'app',
          'extra': <String, dynamic>{'uid': 7},
        },
      })) as JoinedMessage;
      final ProviderInfo p = j.provider!;
      expect(p.callId, 'c2');
      expect(p.name, 'agora');
      expect(p.room, 'room-1');
      expect(p.token, 'tok');
      expect(p.appId, 'app');
      expect(p.url, isNull);
      expect(p.extra?['uid'], 7);
    });

    test('peer_joined / peer_left', () {
      final PeerJoinedMessage pj = ServerMessage.decode(
          '{"t":"peer_joined","call_id":"c1","pid":"p2","user_id":"bob"}') as PeerJoinedMessage;
      expect(pj.callId, 'c1');
      expect(pj.peer.pid, 'p2');
      expect(pj.peer.userId, 'bob');
      final PeerLeftMessage pl = ServerMessage.decode(
          '{"t":"peer_left","call_id":"c1","pid":"p2","user_id":"bob","reason":"left"}') as PeerLeftMessage;
      expect(pl.reason, 'left');
      expect(pl.peer.pid, 'p2');
    });

    test('peer_joined epoch: a new epoch for a known pid means a new link', () {
      final PeerJoinedMessage pj = ServerMessage.decode(
          '{"t":"peer_joined","call_id":"c1","pid":"p2","user_id":"bob","epoch":2}') as PeerJoinedMessage;
      expect(pj.peer.epoch, 2);
      expect(isStalePeerEpoch(1, 2), isTrue);
      expect(isStalePeerEpoch(2, 2), isFalse);
      expect(isStalePeerEpoch(null, 2), isFalse);
      expect(isStalePeerEpoch(1, null), isFalse);
      const PeerInfo noEpoch = PeerInfo(pid: 'p2', userId: 'bob');
      expect(noEpoch.withEpochFrom(pj.peer).epoch, 2);
      final JoinedMessage j = ServerMessage.decode(
              '{"t":"joined","pid":"p1","call":{"id":"c1","mode":"audio","engine":"catz"},"peers":[{"pid":"p2","user_id":"bob","epoch":3}]}')
          as JoinedMessage;
      expect(j.peers.single.epoch, 3);
    });

    test('signal payloads', () {
      final SignalMessage offer = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'signal',
        'call_id': 'c1',
        'from': 'p2',
        'data': <String, dynamic>{
          'sdp': <String, dynamic>{'type': 'offer', 'sdp': 'v=0\r\n'},
        },
      })) as SignalMessage;
      expect(offer.from, 'p2');
      expect(offer.data.sdp?.type, 'offer');
      expect(offer.data.sdp?.sdp, 'v=0\r\n');
      expect(offer.data.candidate, isNull);
      expect(offer.data.restart, isFalse);

      final SignalMessage cand = ServerMessage.decode(jsonEncode(<String, dynamic>{
        't': 'signal',
        'call_id': 'c1',
        'from': 'p2',
        'data': <String, dynamic>{
          'candidate': <String, dynamic>{
            'candidate': 'candidate:1 1 udp 2122260223 192.0.2.1 54400 typ host',
            'sdpMid': '0',
            'sdpMLineIndex': 0,
          },
        },
      })) as SignalMessage;
      expect(cand.data.candidate?.sdpMid, '0');
      expect(cand.data.candidate?.sdpMLineIndex, 0);

      final SignalMessage endOfCandidates = ServerMessage.decode(
          '{"t":"signal","call_id":"c1","from":"p2","data":{"candidate":null}}') as SignalMessage;
      expect(endOfCandidates.data.isEmpty, isTrue);

      final SignalMessage restart = ServerMessage.decode(
          '{"t":"signal","call_id":"c1","from":"p2","data":{"restart":true}}') as SignalMessage;
      expect(restart.data.restart, isTrue);
    });

    test('state, ice_refresh, error, ping, unknown', () {
      final StateMessage s =
          ServerMessage.decode('{"t":"state","call_id":"c1","status":"declined","reason":"busy"}') as StateMessage;
      expect(s.event.status, CallStatus.declined);
      expect(s.event.status.isFinal, isTrue);
      expect(s.event.reason, 'busy');
      expect(CallStatus.parse('active').isFinal, isFalse);
      expect(CallStatus.parse('cancelled'), CallStatus.canceled);
      expect(CallStatus.parse('weird'), CallStatus.unknown);

      final IceRefreshMessage r = ServerMessage.decode(
          '{"t":"ice_refresh","ice_servers":[{"urls":["turn:h:3478"],"username":"u","credential":"c"}]}')
          as IceRefreshMessage;
      expect(r.iceServers.single.credential, 'c');

      final ErrorMessage e = ServerMessage.decode(
          '{"t":"error","code":"minutes_cap_reached","message":"Monthly minutes used up.","call_id":"c1"}')
          as ErrorMessage;
      expect(e.error.code, 'minutes_cap_reached');
      expect(e.error.callId, 'c1');

      final PingMessage p = ServerMessage.decode('{"t":"ping","ts":1700000000123}') as PingMessage;
      expect(p.ts, 1700000000123);

      final ServerMessage u = ServerMessage.decode('{"t":"future_thing","x":1}');
      expect(u, isA<UnknownMessage>());
      expect(u.type, 'future_thing');
    });

    test('rejects malformed frames', () {
      expect(() => ServerMessage.decode('not json'), throwsFormatException);
      expect(() => ServerMessage.decode('[1,2]'), throwsFormatException);
      expect(() => ServerMessage.decode('{"x":1}'), throwsFormatException);
    });
  });

  group('client messages', () {
    test('join / accept / decline / leave / cancel', () {
      expect(_decodeFrame(ClientMessage.join('c1', audio: true, video: false).encode()), <String, dynamic>{
        't': 'join',
        'call_id': 'c1',
        'media': <String, dynamic>{'audio': true, 'video': false},
      });
      expect(_decodeFrame(ClientMessage.accept('c1').encode()), <String, dynamic>{'t': 'accept', 'call_id': 'c1'});
      expect(_decodeFrame(ClientMessage.decline('c1').encode()), <String, dynamic>{'t': 'decline', 'call_id': 'c1'});
      expect(_decodeFrame(ClientMessage.leave('c1').encode()), <String, dynamic>{'t': 'leave', 'call_id': 'c1'});
      expect(_decodeFrame(ClientMessage.cancel('c1').encode()), <String, dynamic>{'t': 'cancel', 'call_id': 'c1'});
    });

    test('signal round-trips', () {
      final ClientMessage offer = ClientMessage.signal('c1', 'p2', SignalData.description('offer', 'v=0'));
      final Map<String, dynamic> json = _decodeFrame(offer.encode());
      expect(json['t'], 'signal');
      expect(json['to'], 'p2');
      expect(json['data'], <String, dynamic>{
        'sdp': <String, dynamic>{'type': 'offer', 'sdp': 'v=0'},
      });
      final SignalData back = SignalData.fromJson(json['data'] as Map<String, dynamic>);
      expect(back.sdp?.type, 'offer');

      final ClientMessage cand =
          ClientMessage.signal('c1', 'p2', SignalData.iceCandidate('candidate:1 1 udp 1 1.2.3.4 1 typ relay', '0', 0));
      expect(_decodeFrame(cand.encode())['data'], <String, dynamic>{
        'candidate': <String, dynamic>{
          'candidate': 'candidate:1 1 udp 1 1.2.3.4 1 typ relay',
          'sdpMid': '0',
          'sdpMLineIndex': 0,
        },
      });

      expect(_decodeFrame(ClientMessage.signal('c1', 'p2', SignalData.restartRequest()).encode())['data'],
          <String, dynamic>{'restart': true});
    });

    test('stats rounds values and omits unknown ones', () {
      final Map<String, dynamic> s = _decodeFrame(ClientMessage.stats(
        'c1',
        connection: ConnectionType.relay,
        rttMs: 81.6,
        jitterMs: null,
        lossPct: 1.23456,
        bitrateKbps: 512.4,
      ).encode());
      expect(s, <String, dynamic>{
        't': 'stats',
        'call_id': 'c1',
        'connection': 'relay',
        'rtt_ms': 82,
        'loss_pct': 1.23,
        'bitrate_kbps': 512,
      });
    });

    test('pong echoes ts, resume carries pid', () {
      expect(_decodeFrame(ClientMessage.pong(42).encode()), <String, dynamic>{'t': 'pong', 'ts': 42});
      expect(_decodeFrame(ClientMessage.resume('c1', 'p1').encode()),
          <String, dynamic>{'t': 'resume', 'call_id': 'c1', 'pid': 'p1'});
    });

    test('queueable', () {
      expect(ClientMessage.signal('c', 'p', SignalData.restartRequest()).queueable, isTrue);
      expect(ClientMessage.leave('c').queueable, isTrue);
      expect(ClientMessage.pong(1).queueable, isFalse);
      expect(ClientMessage.resume('c', 'p').queueable, isFalse);
      expect(ClientMessage.stats('c', connection: ConnectionType.direct).queueable, isFalse);
    });
  });

  group('politeness', () {
    test('larger pid is polite', () {
      expect(isPolite('b', 'a'), isTrue);
      expect(isPolite('a', 'b'), isFalse);
      const String low = '0f1c2a3e-0000-4000-8000-000000000000';
      const String high = 'f01c2a3e-0000-4000-8000-000000000000';
      expect(isPolite(high, low), isTrue);
      expect(isPolite(low, high), isFalse);
      // Exactly one side of a pair is polite.
      expect(isPolite(high, low) != isPolite(low, high), isTrue);
    });

    test('polite_for from the server wins', () {
      expect(isPolite('a', 'b', politeFor: <String, bool>{'b': true}), isTrue);
      expect(isPolite('b', 'a', politeFor: <String, bool>{'a': false}), isFalse);
      expect(isPolite('b', 'a', politeFor: <String, bool>{'x': false}), isTrue);
    });
  });

  group('tokens and urls', () {
    String b64(Map<String, dynamic> m) => base64Url.encode(utf8.encode(jsonEncode(m))).replaceAll('=', '');

    test('tokenExpiry reads exp from ct1 tokens', () {
      final String token = 'ct1.${b64(<String, dynamic>{'v': 1, 'org': 'o', 'uid': 'u', 'exp': 1900000000})}.sig';
      expect(tokenExpiry(token), 1900000000);
      expect(tokenExpiry('ct1.%%%.sig'), isNull);
      expect(tokenExpiry('jwt.a.b'), isNull);
      expect(tokenExpiry('ct1.${b64(<String, dynamic>{'v': 1})}.sig'), isNull);
    });

    test('buildSocketUri adds the token', () {
      final Uri u = buildSocketUri('wss://api.catzconnect.com/rtc/v1/ws', 'ct1.a+b/c.d');
      expect(u.scheme, 'wss');
      expect(u.path, '/rtc/v1/ws');
      expect(u.queryParameters['token'], 'ct1.a+b/c.d');
      final Uri v = buildSocketUri('ws://localhost:8080/rtc/v1/ws?debug=1', 't');
      expect(v.queryParameters, <String, String>{'debug': '1', 'token': 't'});
    });

    test('auth error codes', () {
      expect(isAuthErrorCode('token_expired'), isTrue);
      expect(isAuthErrorCode('UNAUTHORIZED'), isTrue);
      expect(isAuthErrorCode('minutes_cap_reached'), isFalse);
      expect(isAuthErrorCode(null), isFalse);
      expect(isAuthErrorCode('rate_limited'), isFalse);
    });

    test('auth close codes: 4401/4403 only; 1008 and 4008 reconnect', () {
      expect(isAuthCloseCode(4401), isTrue);
      expect(isAuthCloseCode(4403), isTrue);
      expect(isAuthCloseCode(1008), isFalse);
      expect(isAuthCloseCode(4008), isFalse);
      expect(isAuthCloseCode(null), isFalse);
      expect(kOverloadCloseCode, 4008);
    });
  });
}
