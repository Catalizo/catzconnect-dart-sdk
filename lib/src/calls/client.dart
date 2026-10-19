// CatzCallClient: Flutter call client for Catz Connect (engine `catz`:
// peer-to-peer WebRTC mesh through our STUN/TURN relay; provider engines
// are handed off through the `provider` stream).

import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart' show Helper, MediaStream, MediaStreamTrack, navigator;

import 'models.dart';
import 'peer.dart';
import 'protocol.dart';
import 'signaling.dart';
import 'stats.dart';

/// How long to wait for `joined` after `join` / `accept`.
const Duration _joinTimeout = Duration(seconds: 15);

/// After sending `resume`, an `error` within this window means the server
/// did not take it, and the client joins again.
const Duration _resumeConfirm = Duration(seconds: 5);

/// Media from a remote participant. The same [stream] object is emitted
/// again when it gains a track (audio first, then video).
class RemoteStreamEvent {
  const RemoteStreamEvent({required this.callId, required this.peer, required this.stream, required this.track});

  final String callId;
  final PeerInfo peer;
  final MediaStream stream;
  final MediaStreamTrack track;
}

/// The local camera/microphone stream (or the screen-share preview when
/// [screen] is true). [stream] is null once the call ended and the devices
/// were released.
class LocalStreamEvent {
  const LocalStreamEvent({required this.stream, this.screen = false});

  final MediaStream? stream;
  final bool screen;
}

/// A provider-engine call: join it with that provider's SDK.
class ProviderEvent {
  const ProviderEvent({required this.callId, required this.call, required this.provider});

  final String callId;
  final CallInfo call;
  final ProviderInfo provider;
}

/// Result of [CatzCallClient.join] / [CatzCallClient.accept].
class JoinResult {
  const JoinResult({required this.call, required this.pid, required this.peers, this.provider});

  final CallInfo call;

  /// This participant's id, when the server sent it.
  final String? pid;

  /// Participants already in the call.
  final List<PeerInfo> peers;

  /// Set when the call runs on a provider engine (no WebRTC is opened here).
  final ProviderInfo? provider;
}

class _ActiveCall {
  _ActiveCall({
    required this.id,
    required this.info,
    required this.mode,
    required this.pid,
    required this.audio,
    required this.video,
    required this.provider,
    required this.politeFor,
    this.ice,
  });

  final String id;
  CallInfo info;
  CallMode mode;
  String? pid;
  bool audio;
  bool video;
  ProviderInfo? provider;
  Map<String, bool> politeFor;

  /// STUN + TURN for this call (`joined.ice_servers`, renewed by `ice_refresh`).
  List<IceServer>? ice;
}

/// `platform` sent on join (stored per participant).
String _platformName() {
  if (kIsWeb) return 'web';
  return switch (defaultTargetPlatform) {
    TargetPlatform.android => 'android',
    TargetPlatform.iOS => 'ios',
    TargetPlatform.macOS => 'macos',
    TargetPlatform.windows => 'windows',
    TargetPlatform.linux => 'linux',
    TargetPlatform.fuchsia => 'fuchsia',
  };
}

class _PendingJoin {
  _PendingJoin(this.callId, this.audio, this.video, this.completer);

  final String callId;
  final bool audio;
  final bool video;
  final Completer<JoinResult> completer;
  Timer? timer;
}

/// Flutter client for Catz Connect voice and video calls.
///
/// ```dart
/// final client = CatzCallClient(getToken: () => myBackend.fetchCallToken());
/// client.incoming.listen((call) => showRinging(call));
/// client.remoteStreams.listen((e) => renderers[e.peer.pid]!.srcObject = e.stream);
/// await client.connect();
/// await client.join(callIdFromYourBackend, audio: true, video: true);
/// ```
///
/// The connection is kept up without hanging up: ICE prefers a direct path
/// and falls back to the relay by itself; a failed or long-disconnected path
/// is ICE-restarted with backoff; a dropped WebSocket reconnects with
/// backoff + jitter and resumes the call within the server's 30 s grace (or
/// joins again after it), renewing the token through `getToken`.
class CatzCallClient {
  /// Pass either a fixed user [token] (from `calls.token` on your backend) or
  /// [getToken], which is called whenever a fresh token is needed (so long
  /// calls survive token expiry and reconnects). [url] defaults to the
  /// production endpoint; use `ws_url` from `calls.token` when it differs.
  CatzCallClient({
    String? token,
    Future<String> Function()? getToken,
    String url = kDefaultCallsUrl,
    this.resumeGrace = kResumeGrace,
    this.statsInterval = const Duration(seconds: 10),
    Map<String, dynamic>? rtcConfig,
    SocketConnector? connector,
  })  : _token = (token == null || token.isEmpty) ? null : token,
        _getToken = getToken,
        _url = url,
        _connector = connector,
        _rtcExtra = rtcConfig ?? const <String, dynamic>{} {
    if ((token == null || token.isEmpty) && getToken == null) {
      throw ArgumentError('Pass a token or getToken to CatzCallClient.');
    }
  }

  final String? _token;
  final Future<String> Function()? _getToken;
  final String _url;
  final SocketConnector? _connector;
  final Map<String, dynamic> _rtcExtra;

  /// How long a dropped socket may stay away and still `resume`.
  final Duration resumeGrace;

  /// Interval for `quality` events and `stats` frames.
  final Duration statsInterval;

  // Streams --------------------------------------------------------------

  final StreamController<IncomingCall> _incoming = StreamController<IncomingCall>.broadcast();
  final StreamController<CallStateEvent> _state = StreamController<CallStateEvent>.broadcast();
  final StreamController<PeerJoinedEvent> _peerJoined = StreamController<PeerJoinedEvent>.broadcast();
  final StreamController<PeerLeftEvent> _peerLeft = StreamController<PeerLeftEvent>.broadcast();
  final StreamController<RemoteStreamEvent> _remoteStreams = StreamController<RemoteStreamEvent>.broadcast();
  final StreamController<LocalStreamEvent> _localStream = StreamController<LocalStreamEvent>.broadcast();
  final StreamController<ConnectionEvent> _connection = StreamController<ConnectionEvent>.broadcast();
  final StreamController<CallQuality> _quality = StreamController<CallQuality>.broadcast();
  final StreamController<ReconnectingEvent> _reconnecting = StreamController<ReconnectingEvent>.broadcast();
  final StreamController<ReconnectedEvent> _reconnected = StreamController<ReconnectedEvent>.broadcast();
  final StreamController<ProviderEvent> _provider = StreamController<ProviderEvent>.broadcast();
  final StreamController<CallError> _errors = StreamController<CallError>.broadcast();
  final StreamController<String> _closedCtl = StreamController<String>.broadcast();

  /// Someone is calling this user (sent while the call rings).
  Stream<IncomingCall> get incoming => _incoming.stream;

  /// Call status changes (ringing → active → ended/missed/declined/...).
  Stream<CallStateEvent> get state => _state.stream;
  Stream<PeerJoinedEvent> get peerJoined => _peerJoined.stream;
  Stream<PeerLeftEvent> get peerLeft => _peerLeft.stream;

  /// Remote media, one stream per peer.
  Stream<RemoteStreamEvent> get remoteStreams => _remoteStreams.stream;

  /// Local camera/mic stream (also after switchCamera / shareScreen /
  /// stopShare, and `null` when released).
  Stream<LocalStreamEvent> get localStream => _localStream.stream;

  /// Media path per peer: direct or relay. Emitted on change.
  Stream<ConnectionEvent> get connection => _connection.stream;

  /// Per-peer quality sample every [statsInterval].
  Stream<CallQuality> get quality => _quality.stream;

  /// Signaling or a peer path dropped and is being restored.
  Stream<ReconnectingEvent> get reconnecting => _reconnecting.stream;
  Stream<ReconnectedEvent> get reconnected => _reconnected.stream;

  /// The call runs on a provider engine: hand off to that provider's SDK.
  Stream<ProviderEvent> get provider => _provider.stream;

  /// Server `error` frames and local failures (media, negotiation, ...).
  Stream<CallError> get errors => _errors.stream;

  /// The client was closed (by [dispose], or because it cannot
  /// authenticate any more). Carries the reason.
  Stream<String> get closed => _closedCtl.stream;

  // State ----------------------------------------------------------------

  SignalingSocket? _sig;
  Future<void>? _connecting;
  bool _disposed = false;
  List<IceServer> _iceServers = <IceServer>[];
  int _maxParticipants = 4;
  _ActiveCall? _call;
  final Map<String, PeerSession> _peers = <String, PeerSession>{};
  final Map<String, CallInfo> _ringing = <String, CallInfo>{};
  _PendingJoin? _pendingJoin;
  bool _settingUp = false;
  final List<ServerMessage> _deferred = <ServerMessage>[];

  MediaStream? _local;
  bool _ownsLocal = false;
  MediaStream? _screenStream;
  MediaStreamTrack? _screenTrack;
  bool _audioMuted = false;
  bool _videoMuted = false;

  Timer? _statsTimer;
  DateTime? _downAt;
  Timer? _resumeTimer;

  /// True while the signaling socket is open.
  bool get isConnected => _sig?.isOpen ?? false;

  /// The call this client is in, or null.
  String? get callId => _call?.id;

  /// This participant's id in the current call (when the server sent it).
  String? get pid => _call?.pid;

  /// The local camera/mic stream, once acquired.
  MediaStream? get localMediaStream => _local;

  /// The screen being shared, if any.
  MediaStream? get screenStream => _screenStream;
  bool get isSharingScreen => _screenTrack != null;

  /// Remote participants in the current call.
  List<PeerInfo> get peers => _peers.values.map((PeerSession s) => s.peer).toList(growable: false);

  /// Remote stream for a participant.
  MediaStream? remoteStream(String pid) => _peers[pid]?.remoteStream;

  /// Last known media path to a participant.
  ConnectionType? connectionOf(String pid) => _peers[pid]?.connectionType;

  bool isMuted(MediaKind kind) => kind == MediaKind.audio ? _audioMuted : _videoMuted;

  /// ICE servers in use: the current call's (`joined` / `ice_refresh`, with
  /// TURN), else the STUN servers from the last `hello`.
  List<IceServer> get iceServers => List<IceServer>.unmodifiable(_call?.ice ?? _iceServers);

  void _applyIce() {
    final Map<String, dynamic> cfg = _rtcConfiguration();
    for (final PeerSession p in _peers.values) {
      unawaited(p.setConfiguration(cfg));
    }
  }

  // Connection -----------------------------------------------------------

  /// Opens signaling and waits for the server's `hello`. Safe to call more
  /// than once. Throws [CallError] (`connect_failed`, `token_expired`, ...).
  Future<void> connect() {
    if (_disposed) return Future<void>.error(const CallError('closed', 'The call client is closed.'));
    final SignalingSocket? existing = _sig;
    if (existing != null && existing.isOpen) return Future<void>.value();
    final Future<void>? pending = _connecting;
    if (pending != null) return pending;

    SignalingSocket sig;
    if (existing != null && !existing.isClosed) {
      sig = existing;
    } else {
      sig = SignalingSocket(url: _url, token: _token, getToken: _getToken, connector: _connector);
      sig.onMessage = _onMessage;
      sig.onOpen = _onOpen;
      sig.onDown = _onDown;
      sig.onFatal = (CallError err) {
        _emitError(err);
        unawaited(_shutdown(err.code));
      };
      _sig = sig;
    }
    final Future<void> f = sig.connect().then((HelloMessage _) {});
    _connecting = f;
    return f.whenComplete(() {
      if (identical(_connecting, f)) _connecting = null;
    });
  }

  /// Call this when the device's network changed (e.g. from a
  /// connectivity listener): reconnects signaling at once and restarts ICE
  /// on live peer connections.
  void notifyNetworkChanged() {
    _sig?.reconnectNow();
    for (final PeerSession p in _peers.values) {
      p.onNetworkChange();
    }
  }

  void _send(ClientMessage m, {bool force = false}) {
    _sig?.send(m, force: force);
  }

  void _onOpen(HelloMessage hello, bool reconnect) {
    // hello has STUN only: a call's TURN credentials stay until `joined` /
    // `ice_refresh` renews them.
    _iceServers = hello.iceServers;
    final int? maxP = hello.maxParticipants;
    if (maxP != null && maxP > 0) _maxParticipants = maxP;
    if (_call?.ice == null) _applyIce();
    if (!reconnect) return;

    final DateTime? downAt = _downAt;
    final Duration downFor = downAt == null ? Duration.zero : DateTime.now().difference(downAt);
    _downAt = null;

    final _ActiveCall? call = _call;
    if (call != null && call.provider == null) {
      call.pid ??= hello.resumePidFor(call.id);
      final String? myPid = call.pid;
      if (myPid != null && downFor <= resumeGrace) {
        // Written before the queued frames are flushed.
        _send(ClientMessage.resume(call.id, myPid), force: true);
        _resumeTimer?.cancel();
        _resumeTimer = Timer(_resumeConfirm, () => _resumeTimer = null);
      } else {
        _rejoin('grace_expired');
      }
      // Peers whose path broke while we were away restart once frames flow.
      Timer.run(() {
        for (final PeerSession p in _peers.values) {
          p.onSignalingRestored();
        }
      });
    }
    _emit<ReconnectedEvent>(_reconnected, ReconnectedEvent(scope: ReconnectScope.signaling, callId: call?.id));
  }

  void _onDown(int attempt, Duration delay) {
    _downAt ??= DateTime.now();
    _emit<ReconnectingEvent>(
      _reconnecting,
      ReconnectingEvent(scope: ReconnectScope.signaling, attempt: attempt, delay: delay, callId: _call?.id),
    );
  }

  /// The grace ran out or the server refused the resume: join again with a
  /// new pid, keeping local media.
  void _rejoin(String reason) {
    final _ActiveCall? call = _call;
    if (call == null || call.provider != null) return;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    final List<PeerSession> old = _peers.values.toList();
    _peers.clear();
    for (final PeerSession p in old) {
      unawaited(p.close());
      _emit<PeerLeftEvent>(_peerLeft, PeerLeftEvent(callId: call.id, peer: p.peer, reason: reason));
    }
    _sig?.dropQueued((ClientMessage m) => m.type == 'signal' || m.type == 'resume');
    call.pid = null;
    _sendJoin(call.id, accept: false, audio: call.audio, video: call.video).catchError((Object e) {
      _emitError(CallError('rejoin_failed', '$e', callId: call.id));
      return JoinResult(call: call.info, pid: null, peers: const <PeerInfo>[]);
    });
  }

  // Server frames --------------------------------------------------------

  void _onMessage(ServerMessage m) {
    if (_disposed) return;
    // While local media is being set up for a fresh join, hold frames of
    // that call so peer connections are created with the tracks attached.
    if (_settingUp && _isCallScoped(m)) {
      _deferred.add(m);
      return;
    }
    _dispatch(m);
  }

  bool _isCallScoped(ServerMessage m) =>
      m is PeerJoinedMessage || m is PeerLeftMessage || m is SignalMessage;

  void _dispatch(ServerMessage m) {
    if (m is IncomingMessage) {
      final CallInfo call = m.call;
      if (call.id.isEmpty) return;
      _ringing[call.id] = call;
      _emit<IncomingCall>(_incoming, IncomingCall.fromCall(call));
    } else if (m is JoinedMessage) {
      _onJoined(m);
    } else if (m is PeerJoinedMessage) {
      final _ActiveCall? call = _call;
      if (call == null || m.callId != call.id || call.provider != null || m.peer.pid.isEmpty) return;
      final PeerSession? existing = _peers[m.peer.pid];
      if (existing != null && isStalePeerEpoch(existing.peer.epoch, m.peer.epoch)) {
        // The participant joined again (another device: new DTLS identity);
        // the old connection cannot renegotiate with it. Replace it — the
        // newcomer sends a fresh offer.
        _peers.remove(m.peer.pid);
        unawaited(existing.close());
        _createPeer(m.peer, initiator: false);
      } else if (existing != null) {
        existing.peer = m.peer.withEpochFrom(existing.peer);
      } else {
        _createPeer(m.peer, initiator: false);
      }
      _emit<PeerJoinedEvent>(_peerJoined, PeerJoinedEvent(callId: m.callId, peer: m.peer));
    } else if (m is PeerLeftMessage) {
      final _ActiveCall? call = _call;
      if (call == null || m.callId != call.id) return;
      final PeerSession? s = _peers.remove(m.peer.pid);
      if (s != null) unawaited(s.close());
      _emit<PeerLeftEvent>(_peerLeft, PeerLeftEvent(callId: m.callId, peer: m.peer, reason: m.reason));
    } else if (m is SignalMessage) {
      final _ActiveCall? call = _call;
      if (call == null || m.callId != call.id || call.provider != null || m.from.isEmpty) return;
      // An offer can overtake peer_joined; open the session now and learn
      // the user id later.
      final PeerSession s = _peers[m.from] ?? _createPeer(PeerInfo(pid: m.from, userId: ''), initiator: false);
      s.handleSignal(m.data);
    } else if (m is StateMessage) {
      final CallStateEvent ev = m.event;
      if (ev.status.isFinal) _ringing.remove(ev.callId);
      // Another device of this user answered / declined: stop ringing here.
      // 'missed': this user did not answer in time while a group call goes on.
      if (ev.reason == 'answered_elsewhere' || ev.reason == 'declined_elsewhere' || ev.reason == 'missed') {
        _ringing.remove(ev.callId);
      }
      // joined_elsewhere: the participant moved to another device of this
      // user; the call goes on there, so tear down here without `leave`.
      final bool replaced = ev.reason == 'joined_elsewhere' && !ev.status.isFinal;
      final _ActiveCall? call = _call;
      if (call != null && call.id == ev.callId && (ev.status.isFinal || replaced)) {
        unawaited(_teardown());
      }
      final _PendingJoin? pj = _pendingJoin;
      if (pj != null && pj.callId == ev.callId && ev.status.isFinal) {
        _failJoin(CallError('call_${ev.status.name}', 'The call is ${ev.status.name}.', callId: ev.callId));
      }
      _emit<CallStateEvent>(_state, ev);
    } else if (m is IceRefreshMessage) {
      final _ActiveCall? call = _call;
      if (call == null || m.iceServers.isEmpty) return;
      if (m.callId != null && m.callId != call.id) return; // another call's credentials
      call.ice = m.iceServers;
      _applyIce();
    } else if (m is ErrorMessage) {
      final CallError err = m.error;
      final String? errCallId = err.callId;
      final _PendingJoin? pj = _pendingJoin;
      final _ActiveCall? call = _call;
      if (pj != null && (errCallId == null || errCallId == pj.callId) && !isAuthErrorCode(err.code)) {
        _failJoin(err);
      } else if (_resumeTimer != null &&
          call != null &&
          (errCallId == null || errCallId == call.id) &&
          !isAuthErrorCode(err.code)) {
        // The server did not take the resume (grace over, other process).
        _rejoin(err.code);
      }
      if (isAuthErrorCode(err.code)) _sig?.markTokenStale();
      _emitError(err);
    }
  }

  void _onJoined(JoinedMessage m) {
    final CallInfo info = m.call;
    final _PendingJoin? pending =
        (_pendingJoin != null && (_pendingJoin!.callId == info.id || info.id.isEmpty)) ? _pendingJoin : null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    final String callId = info.id.isNotEmpty ? info.id : (pending?.callId ?? '');
    final _ActiveCall? current = _call;
    if (pending == null && (current == null || current.id != callId)) return; // not ours

    _ringing.remove(callId);
    final CallMode mode = info.id.isEmpty
        ? ((pending?.video ?? false) ? CallMode.video : CallMode.audio)
        : info.mode;
    final bool audio = pending?.audio ?? current?.audio ?? true;
    bool video = pending?.video ?? current?.video ?? (mode == CallMode.video);
    if (mode == CallMode.audio) video = false;

    final _ActiveCall call = _ActiveCall(
      id: callId,
      info: info,
      mode: mode,
      pid: m.pid ?? (current?.id == callId ? current?.pid : null),
      audio: audio,
      video: video,
      provider: m.provider,
      politeFor: m.politeFor,
      ice: m.iceServers ?? (current?.id == callId ? current?.ice : null),
    );
    _call = call;
    // A resume hands out fresh TURN credentials: apply them to live sessions.
    if (m.iceServers != null) _applyIce();
    final List<PeerInfo> peers = m.peers;

    final ProviderInfo? prov = m.provider;
    if (prov != null) {
      _emit<ProviderEvent>(_provider, ProviderEvent(callId: callId, call: info, provider: prov));
      _settleJoin(pending, JoinResult(call: info, pid: call.pid, peers: peers, provider: prov));
      return;
    }

    _settingUp = true;
    unawaited(_setUpCall(call, peers, pending));
  }

  Future<void> _setUpCall(_ActiveCall call, List<PeerInfo> peers, _PendingJoin? pending) async {
    try {
      await _ensureLocalMedia(audio: call.audio, video: call.video);
      if (!identical(_call, call)) return;

      // Reconcile (after a resume or rejoin): drop sessions to peers that
      // are gone, open the rest as offerer.
      final Set<String> live = peers.map((PeerInfo p) => p.pid).toSet();
      final List<String> gone = _peers.keys.where((String pid) => !live.contains(pid)).toList();
      for (final String pid in gone) {
        final PeerSession? s = _peers.remove(pid);
        if (s != null) unawaited(s.close());
      }
      final int maxP = asInt(call.info.raw['max_participants']) ?? _maxParticipants;
      final int limit = maxP - 1 < 1 ? 1 : maxP - 1;
      int opened = 0;
      for (final PeerInfo peer in peers) {
        if (opened >= limit) break;
        opened++;
        final PeerSession? s = _peers[peer.pid];
        if (s != null && isStalePeerEpoch(s.peer.epoch, peer.epoch)) {
          // The peer rejoined from another device while we were away.
          _peers.remove(peer.pid);
          unawaited(s.close());
          _createPeer(peer, initiator: true);
        } else if (s != null) {
          s.peer = peer.withEpochFrom(s.peer);
        } else {
          _createPeer(peer, initiator: true);
        }
      }
      if (peers.length > limit) {
        _emitError(CallError(
          'too_many_participants',
          'Only ${limit + 1} participants fit a peer-to-peer call.',
          callId: call.id,
        ));
      }
      _startStats();
      _settleJoin(pending, JoinResult(call: call.info, pid: call.pid, peers: peers));
    } catch (e) {
      _emitError(CallError('join_failed', '$e', callId: call.id));
      _settleJoin(pending, JoinResult(call: call.info, pid: call.pid, peers: peers));
    } finally {
      _settingUp = false;
      final List<ServerMessage> held = List<ServerMessage>.from(_deferred);
      _deferred.clear();
      for (final ServerMessage msg in held) {
        _dispatch(msg);
      }
    }
  }

  void _settleJoin(_PendingJoin? pending, JoinResult r) {
    if (pending == null) return;
    pending.timer?.cancel();
    if (identical(_pendingJoin, pending)) _pendingJoin = null;
    if (!pending.completer.isCompleted) pending.completer.complete(r);
  }

  void _failJoin(CallError err) {
    final _PendingJoin? pj = _pendingJoin;
    if (pj == null) return;
    _pendingJoin = null;
    pj.timer?.cancel();
    final _ActiveCall? call = _call;
    if (call != null && call.id == pj.callId && _peers.isEmpty) unawaited(_teardown());
    if (!pj.completer.isCompleted) pj.completer.completeError(err);
  }

  Map<String, dynamic> _rtcConfiguration() {
    final Map<String, dynamic> cfg = <String, dynamic>{
      'sdpSemantics': 'unified-plan',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      'iceTransportPolicy': 'all',
    };
    cfg.addAll(_rtcExtra);
    cfg['iceServers'] = (_call?.ice ?? _iceServers).map((IceServer s) => s.toJson()).toList();
    return cfg;
  }

  PeerSession _createPeer(PeerInfo peer, {required bool initiator}) {
    final _ActiveCall call = _call!;
    final String callId = call.id;
    final String pid = peer.pid;
    final String? myPid = call.pid;
    final bool polite = call.politeFor[pid] ??
        (myPid != null
            ? isPolite(myPid, pid)
            : !initiator); // unknown own pid: the answerer is polite
    final PeerSession session = PeerSession(
      callId: callId,
      peer: peer,
      polite: polite,
      initiator: initiator,
      sendSignal: (SignalData data) => _send(ClientMessage.signal(callId, pid, data)),
      canSignal: () => _sig?.isOpen ?? false,
      onRemoteStream: (PeerSession s, MediaStream stream, MediaStreamTrack track) {
        _emit<RemoteStreamEvent>(
          _remoteStreams,
          RemoteStreamEvent(callId: callId, peer: s.peer, stream: stream, track: track),
        );
      },
      onConnectionType: (PeerSession s, ConnectionType type) {
        _emit<ConnectionEvent>(_connection, ConnectionEvent(callId: callId, peer: s.peer, type: type));
      },
      onReconnecting: (PeerSession s, int attempt) {
        _emit<ReconnectingEvent>(
          _reconnecting,
          ReconnectingEvent(scope: ReconnectScope.peer, attempt: attempt, callId: callId, pid: s.pid),
        );
      },
      onReconnected: (PeerSession s) {
        _emit<ReconnectedEvent>(
          _reconnected,
          ReconnectedEvent(scope: ReconnectScope.peer, callId: callId, pid: s.pid),
        );
      },
      onError: (PeerSession s, CallError e) => _emitError(e),
    );
    _peers[pid] = session;

    final MediaStream? local = _local;
    MediaStreamTrack? audioTrack;
    MediaStreamTrack? cameraTrack;
    if (local != null) {
      final List<MediaStreamTrack> a = local.getAudioTracks();
      if (a.isNotEmpty) audioTrack = a.first;
      final List<MediaStreamTrack> v = local.getVideoTracks();
      if (v.isNotEmpty) cameraTrack = v.first;
    }
    unawaited(session.start(
      configuration: _rtcConfiguration(),
      localStream: local ?? _screenStream,
      audioTrack: audioTrack,
      videoTrack: _screenTrack ?? cameraTrack,
      receiveAudio: true,
      receiveVideo: call.mode == CallMode.video,
    ));
    return session;
  }

  // Media ----------------------------------------------------------------

  static Map<String, dynamic> _videoConstraints() => <String, dynamic>{
        'facingMode': 'user',
        'mandatory': <String, dynamic>{
          'minWidth': '640',
          'minHeight': '480',
          'minFrameRate': '24',
        },
        'optional': <dynamic>[],
      };

  Future<void> _ensureLocalMedia({required bool audio, required bool video}) async {
    if (_local != null || (!audio && !video)) return;
    MediaStream? stream;
    try {
      stream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': audio,
        'video': video ? _videoConstraints() : false,
      });
    } catch (e) {
      if (audio && video) {
        // No camera (or camera denied): try the microphone alone.
        try {
          stream = await navigator.mediaDevices.getUserMedia(<String, dynamic>{'audio': true, 'video': false});
          _emitError(CallError('media_failed', 'Could not open the camera: $e', callId: _call?.id));
        } catch (_) {
          stream = null;
        }
      }
      if (stream == null) {
        // Join anyway, receive-only, and tell the app why it cannot be heard.
        _emitError(CallError('media_failed', 'Could not open the microphone or camera: $e', callId: _call?.id));
        return;
      }
    }
    _local = stream;
    _ownsLocal = true;
    _applyMute();
    _emit<LocalStreamEvent>(_localStream, LocalStreamEvent(stream: stream));
  }

  void _applyMute() {
    final MediaStream? s = _local;
    if (s == null) return;
    for (final MediaStreamTrack t in s.getAudioTracks()) {
      t.enabled = !_audioMuted;
    }
    for (final MediaStreamTrack t in s.getVideoTracks()) {
      t.enabled = !_videoMuted;
    }
  }

  // Call actions ---------------------------------------------------------

  Future<JoinResult> _sendJoin(String callId, {required bool accept, required bool audio, required bool video}) {
    final _PendingJoin? old = _pendingJoin;
    if (old != null) {
      // Superseded: fail the older join without tearing anything down.
      _pendingJoin = null;
      old.timer?.cancel();
      if (!old.completer.isCompleted) {
        old.completer.completeError(CallError('superseded', 'Superseded by another join.', callId: old.callId));
      }
    }
    final Completer<JoinResult> completer = Completer<JoinResult>();
    final _PendingJoin pj = _PendingJoin(callId, audio, video, completer);
    pj.timer = Timer(_joinTimeout, () {
      if (identical(_pendingJoin, pj)) {
        _failJoin(CallError('join_timeout', 'The server did not answer the join.', callId: callId));
      }
    });
    _pendingJoin = pj;
    final String platform = _platformName();
    _send(accept
        ? ClientMessage.accept(callId, audio: audio, video: video, platform: platform)
        : ClientMessage.join(callId, audio: audio, video: video, platform: platform));
    return completer.future;
  }

  Future<({bool audio, bool video})> _prepareJoin(
    String callId, {
    bool? audio,
    bool? video,
    MediaStream? stream,
  }) async {
    if (callId.trim().isEmpty) throw const CallError('bad_request', 'Missing call id.');
    final _ActiveCall? current = _call;
    if (current != null && current.id != callId) {
      throw CallError('already_in_call', 'Already in a call; leave() first.', callId: current.id);
    }
    await connect();
    final CallInfo? known = _ringing[callId];
    final bool a = audio ?? true;
    final bool v = video ?? (known?.mode == CallMode.video);
    if (stream != null) {
      _local = stream;
      _ownsLocal = false;
      _applyMute();
      _emit<LocalStreamEvent>(_localStream, LocalStreamEvent(stream: stream));
    }
    return (audio: a, video: v);
  }

  /// Joins a call: the caller after creating it on the backend, or anyone
  /// invited. Resolves with the call, this participant's pid and the peers
  /// already in it. For a provider-engine call it resolves with
  /// [JoinResult.provider] (and emits on [provider]) instead of opening peer
  /// connections.
  ///
  /// [audio] defaults to true; [video] defaults to true for a video call
  /// known from [incoming], else false. Pass [stream] to use your own media
  /// (the client does not stop its tracks).
  Future<JoinResult> join(String callId, {bool? audio, bool? video, MediaStream? stream}) async {
    final ({bool audio, bool video}) media = await _prepareJoin(callId, audio: audio, video: video, stream: stream);
    return _sendJoin(callId, accept: false, audio: media.audio, video: media.video);
  }

  /// Answers an incoming call (the callee's alias of [join]).
  Future<JoinResult> accept(String callId, {bool? audio, bool? video, MediaStream? stream}) async {
    final ({bool audio, bool video}) media = await _prepareJoin(callId, audio: audio, video: video, stream: stream);
    return _sendJoin(callId, accept: true, audio: media.audio, video: media.video);
  }

  /// Declines an incoming call.
  Future<void> decline(String callId) async {
    _ringing.remove(callId);
    await connect();
    _send(ClientMessage.decline(callId));
  }

  /// The caller hangs up while it is still ringing (defaults to the current
  /// call).
  Future<void> cancel([String? callId]) async {
    final String? id = callId ?? _call?.id;
    if (id == null) return;
    _send(ClientMessage.cancel(id));
    final _PendingJoin? pj = _pendingJoin;
    if (pj != null && pj.callId == id) _failJoin(CallError('canceled', 'The call was canceled.', callId: id));
    if (_call?.id == id) await _teardown();
  }

  /// Leaves the current call and releases the camera and microphone.
  Future<void> leave() async {
    final _ActiveCall? call = _call;
    if (call == null) return;
    _send(ClientMessage.leave(call.id));
    final _PendingJoin? pj = _pendingJoin;
    if (pj != null && pj.callId == call.id) _failJoin(CallError('left', 'Left the call.', callId: call.id));
    await _teardown();
  }

  /// Mutes or unmutes the microphone ([MediaKind.audio]) or camera
  /// ([MediaKind.video]) without renegotiating. Unmuting the camera in a
  /// call that has none yet opens it and adds it to every peer.
  Future<void> setMuted(MediaKind kind, bool muted) async {
    if (kind == MediaKind.audio) {
      _audioMuted = muted;
    } else {
      _videoMuted = muted;
    }
    _applyMute();
    if (muted) return;

    final _ActiveCall? call = _call;
    if (call == null || call.provider != null) return;
    final MediaStream? local = _local;
    final bool missing = local == null ||
        (kind == MediaKind.audio ? local.getAudioTracks().isEmpty : local.getVideoTracks().isEmpty);
    if (!missing) return;

    // Acquire the missing device and send it.
    final MediaStream extra;
    try {
      extra = await navigator.mediaDevices.getUserMedia(<String, dynamic>{
        'audio': kind == MediaKind.audio,
        'video': kind == MediaKind.video ? _videoConstraints() : false,
      });
    } catch (e) {
      _emitError(CallError('media_failed', 'Could not open the ${kind == MediaKind.audio ? 'microphone' : 'camera'}: $e',
          callId: call.id));
      return;
    }
    if (!identical(_call, call)) {
      for (final MediaStreamTrack t in extra.getTracks()) {
        await t.stop();
      }
      return;
    }
    final List<MediaStreamTrack> tracks =
        kind == MediaKind.audio ? extra.getAudioTracks() : extra.getVideoTracks();
    if (tracks.isEmpty) return;
    final MediaStreamTrack track = tracks.first;
    MediaStream target;
    if (local == null) {
      target = extra;
      _local = extra;
      _ownsLocal = true;
    } else {
      target = local;
      await local.addTrack(track);
    }
    if (kind == MediaKind.video) call.video = true;
    if (kind == MediaKind.audio) call.audio = true;
    for (final PeerSession p in _peers.values.toList()) {
      if (kind == MediaKind.audio) {
        await p.setAudioTrack(track, target);
      } else if (_screenTrack == null) {
        await p.setVideoTrack(track, target);
      }
    }
    _emit<LocalStreamEvent>(_localStream, LocalStreamEvent(stream: target));
  }

  /// Switches between front and back camera. Returns true for the front
  /// camera (as reported by flutter_webrtc). Throws [CallError] when no
  /// camera is in use or the platform cannot switch.
  Future<bool> switchCamera() async {
    final MediaStream? local = _local;
    final List<MediaStreamTrack> v = local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (local == null || v.isEmpty) throw const CallError('no_camera', 'No camera in use.');
    try {
      final bool front = await Helper.switchCamera(v.first);
      _emit<LocalStreamEvent>(_localStream, LocalStreamEvent(stream: local));
      return front;
    } catch (e) {
      throw CallError('not_supported', 'Could not switch camera: $e', callId: _call?.id);
    }
  }

  /// Shares the screen in place of the camera (replaceTrack; adds a video
  /// sender in an audio call). Works on Android (needs a media-projection
  /// foreground service, see README), web and desktop; iOS needs a
  /// broadcast extension and is not supported out of the box.
  Future<void> shareScreen() async {
    final _ActiveCall? call = _call;
    if (call == null || call.provider != null) {
      throw const CallError('not_in_call', 'Not in a peer-to-peer call.');
    }
    if (_screenTrack != null) return;
    final MediaStream screen;
    try {
      screen = await navigator.mediaDevices.getDisplayMedia(<String, dynamic>{'video': true, 'audio': false});
    } catch (e) {
      throw CallError('not_supported', 'Screen sharing is not available: $e', callId: call.id);
    }
    final List<MediaStreamTrack> tracks = screen.getVideoTracks();
    if (tracks.isEmpty) {
      for (final MediaStreamTrack t in screen.getTracks()) {
        await t.stop();
      }
      throw CallError('not_supported', 'Screen sharing returned no video.', callId: call.id);
    }
    final MediaStreamTrack track = tracks.first;
    _screenStream = screen;
    _screenTrack = track;
    track.onEnded = () {
      unawaited(stopShare());
    };
    final MediaStream streamForSender = _local ?? screen;
    for (final PeerSession p in _peers.values.toList()) {
      try {
        await p.setVideoTrack(track, streamForSender);
      } catch (e) {
        _emitError(CallError('screen_share_failed', 'Could not send the screen to ${p.peer.userId}: $e',
            callId: call.id));
      }
    }
    _emit<LocalStreamEvent>(_localStream, LocalStreamEvent(stream: screen, screen: true));
  }

  /// Stops sharing and puts the camera back (or sends no video if there
  /// was none).
  Future<void> stopShare() async {
    final MediaStreamTrack? screenTrack = _screenTrack;
    final MediaStream? screen = _screenStream;
    if (screenTrack == null) return;
    _screenTrack = null;
    _screenStream = null;
    final MediaStream? local = _local;
    final List<MediaStreamTrack> cams = local?.getVideoTracks() ?? const <MediaStreamTrack>[];
    final MediaStreamTrack? camera = cams.isNotEmpty ? cams.first : null;
    for (final PeerSession p in _peers.values.toList()) {
      try {
        await p.setVideoTrack(camera, local);
      } catch (_) {}
    }
    screenTrack.onEnded = null;
    try {
      await screenTrack.stop();
    } catch (_) {}
    if (screen != null) {
      try {
        await screen.dispose();
      } catch (_) {}
    }
    if (local != null) _emit<LocalStreamEvent>(_localStream, LocalStreamEvent(stream: local));
  }

  // Stats ----------------------------------------------------------------

  void _startStats() {
    if (_statsTimer != null) return;
    _statsTimer = Timer.periodic(statsInterval, (Timer t) {
      unawaited(collectStats());
    });
  }

  /// Samples every peer, emits [quality], and sends one aggregated `stats`
  /// frame. Runs every [statsInterval]; exposed for tests and on-demand use.
  Future<void> collectStats() async {
    final _ActiveCall? call = _call;
    if (call == null) return;
    final List<PeerSession> sessions = _peers.values.toList();
    final List<StatsSample> usable = <StatsSample>[];
    for (final PeerSession p in sessions) {
      final StatsSample? s = await p.sampleStats();
      if (s == null) continue;
      if (s.connection != null) usable.add(s);
      _emit<CallQuality>(
        _quality,
        CallQuality(
          callId: call.id,
          peer: p.peer,
          connection: s.connection,
          rttMs: s.rttMs,
          jitterMs: s.jitterMs,
          lossPct: s.lossPct,
          bitrateKbps: s.bitrateKbps,
          level: s.level,
        ),
      );
    }
    if (usable.isEmpty || !identical(_call, call)) return;
    final StatsSummary? sum = StatsSummary.from(usable);
    if (sum == null) return;
    _send(ClientMessage.stats(
      call.id,
      connection: sum.connection,
      rttMs: sum.rttMs,
      jitterMs: sum.jitterMs,
      lossPct: sum.lossPct,
      bitrateKbps: sum.bitrateKbps,
    ));
  }

  // Teardown -------------------------------------------------------------

  Future<void> _teardown() async {
    // Take and clear all call state synchronously, so a second teardown
    // running concurrently finds nothing left to release.
    final _ActiveCall? call = _call;
    _call = null;
    _statsTimer?.cancel();
    _statsTimer = null;
    _resumeTimer?.cancel();
    _resumeTimer = null;
    _deferred.clear();
    if (call != null) {
      final String id = call.id;
      _sig?.dropQueued((ClientMessage m) => m.type == 'signal' && m.fields['call_id'] == id);
    }
    final List<PeerSession> sessions = _peers.values.toList();
    _peers.clear();
    final MediaStreamTrack? screenTrack = _screenTrack;
    final MediaStream? screen = _screenStream;
    _screenTrack = null;
    _screenStream = null;
    final MediaStream? local = _local;
    final bool owns = _ownsLocal;
    _local = null;
    _ownsLocal = false;
    _audioMuted = false;
    _videoMuted = false;
    if (local != null) _emit<LocalStreamEvent>(_localStream, const LocalStreamEvent(stream: null));

    for (final PeerSession p in sessions) {
      try {
        await p.close();
      } catch (_) {}
    }
    if (screenTrack != null) {
      screenTrack.onEnded = null;
      try {
        await screenTrack.stop();
      } catch (_) {}
    }
    if (screen != null) {
      try {
        await screen.dispose();
      } catch (_) {}
    }
    if (local != null && owns) {
      for (final MediaStreamTrack t in local.getTracks()) {
        try {
          await t.stop();
        } catch (_) {}
      }
      try {
        await local.dispose();
      } catch (_) {}
    }
  }

  Future<void> _shutdown(String reason) async {
    if (_disposed) return;
    _disposed = true;
    final _PendingJoin? pj = _pendingJoin;
    if (pj != null) _failJoin(const CallError('closed', 'The call client is closed.'));
    await _teardown();
    final SignalingSocket? sig = _sig;
    _sig = null;
    if (sig != null) await sig.close();
    _emit<String>(_closedCtl, reason);
    for (final StreamController<dynamic> c in <StreamController<dynamic>>[
      _incoming,
      _state,
      _peerJoined,
      _peerLeft,
      _remoteStreams,
      _localStream,
      _connection,
      _quality,
      _reconnecting,
      _reconnected,
      _provider,
      _errors,
      _closedCtl,
    ]) {
      await c.close();
    }
  }

  /// Leaves any call, closes signaling and stops all timers. The client
  /// cannot be reused afterwards.
  Future<void> dispose() async {
    if (_disposed) return;
    final _ActiveCall? call = _call;
    if (call != null) _send(ClientMessage.leave(call.id));
    await _shutdown('closed');
  }

  /// Alias of [dispose] (the browser SDK calls it `close()`).
  Future<void> close() => dispose();

  // Helpers --------------------------------------------------------------

  void _emit<T>(StreamController<T> c, T value) {
    if (!c.isClosed) c.add(value);
  }

  void _emitError(CallError e) => _emit<CallError>(_errors, e);
}
