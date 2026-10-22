// One RTCPeerConnection towards one remote participant, with perfect
// negotiation (polite / impolite), candidate buffering, glare rollback and
// ICE restarts with backoff. Mirrors the browser SDK's `PeerLink`.

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart'
    show
        MediaStream,
        MediaStreamTrack,
        RTCDataChannel,
        RTCDataChannelInit,
        RTCDataChannelMessage,
        RTCDataChannelState,
        RTCIceCandidate,
        RTCIceConnectionState,
        RTCPeerConnection,
        RTCPeerConnectionState,
        RTCRtpEncoding,
        RTCRtpMediaType,
        RTCRtpParameters,
        RTCRtpSender,
        RTCRtpTransceiverInit,
        RTCSessionDescription,
        RTCTrackEvent,
        StatsReport,
        TransceiverDirection,
        createLocalMediaStream,
        createPeerConnection;

import 'backoff.dart';
import 'messages.dart' show kReliableChannelLabel, kUnreliableChannelLabel;
import 'models.dart';
import 'protocol.dart';
import 'stats.dart';
import 'warnings.dart' show VideoTarget;

const String _stable = 'stable';
const String _haveLocalOffer = 'have-local-offer';
const String _haveRemoteOffer = 'have-remote-offer';

/// ICE `disconnected` for longer than this triggers a restart.
const Duration _disconnectedGrace = Duration(seconds: 2);

/// After a restart, check again this much later.
const Duration _restartCheck = Duration(seconds: 10);

/// An answerer that never got an offer makes one itself after this.
const Duration _answererFallback = Duration(seconds: 6);

/// Constraints for an ICE-restart offer. `mandatory.IceRestart` is what the
/// Android/iOS plugins forward to libwebrtc; `iceRestart` is what browsers
/// (flutter_webrtc on web) read. Each platform ignores the other key.
const Map<String, dynamic> _iceRestartConstraints = <String, dynamic>{
  'mandatory': <String, dynamic>{'IceRestart': 'true'},
  'optional': <dynamic>[],
  'iceRestart': true,
};

class PeerSession {
  PeerSession({
    required this.callId,
    required this.peer,
    required this.polite,
    required this.initiator,
    required this.sendSignal,
    required this.canSignal,
    this.onRemoteStream,
    this.onConnectionType,
    this.onReconnecting,
    this.onReconnected,
    this.onError,
    this.onChannelMessage,
  });

  final String callId;

  /// The remote participant (its user id may be learned after creation).
  PeerInfo peer;

  /// Polite side of the pair: on offer collision it rolls back its own offer.
  final bool polite;

  /// The newly joined side: makes the first offer and drives ICE restarts.
  final bool initiator;

  final void Function(SignalData data) sendSignal;

  /// Whether the signaling socket can deliver frames right now.
  final bool Function() canSignal;

  final void Function(PeerSession session, MediaStream stream, MediaStreamTrack track)? onRemoteStream;
  final void Function(PeerSession session, ConnectionType type)? onConnectionType;
  final void Function(PeerSession session, int attempt)? onReconnecting;
  final void Function(PeerSession session)? onReconnected;
  final void Function(PeerSession session, CallError error)? onError;

  /// A text message on one of the session's data channels (in-call chat /
  /// data).
  final void Function(PeerSession session, String text)? onChannelMessage;

  String get pid => peer.pid;

  RTCPeerConnection? _pc;
  RTCPeerConnection? get peerConnection => _pc;

  MediaStream? _remoteStream;
  MediaStream? get remoteStream => _remoteStream;

  RTCRtpSender? _audioSender;
  RTCRtpSender? _videoSender;
  bool _receiveAudio = true;
  bool _receiveVideo = false;
  bool _hasAudioLine = false;
  bool _hasVideoLine = false;

  // Perfect-negotiation state. All SDP work runs on one serial chain, so the
  // signaling state below is always the one our last completed operation
  // produced (native state events can lag behind).
  String _sigState = _stable;
  bool _makingOffer = false;
  bool _ignoreOffer = false;
  bool _remoteDescriptionSet = false;
  bool _initialDone = false;
  bool _needsNegotiation = false;
  bool _needsIceRestart = false;
  bool _runScheduled = false;
  final List<RTCIceCandidate> _pendingCandidates = <RTCIceCandidate>[];
  // Signals that arrive before start() finished wait on this.
  final Completer<void> _started = Completer<void>();
  late Future<void> _chain = _started.future;
  bool _closed = false;
  bool get isClosed => _closed;
  Timer? _answererTimer;

  // ICE recovery.
  RTCIceConnectionState? _iceState;
  RTCIceConnectionState? get iceState => _iceState;
  Timer? _disconnectTimer;
  Timer? _restartTimer;
  Timer? _restartCheckTimer;
  bool _restartWanted = false;
  bool _restarting = false;
  bool _everConnected = false;
  final Backoff _restartBackoff = Backoff(
    initialDelay: const Duration(seconds: 1),
    maxDelay: const Duration(seconds: 15),
    jitter: 0.5,
  );
  int _restartAttempt = 0;

  // In-call message channels (ordered + reliable, and unordered with at
  // most one retransmit), opened by the initiator, adopted by the answerer.
  RTCDataChannel? _reliableChannel;
  RTCDataChannel? _unreliableChannel;
  final Map<String, RTCDataChannelState> _channelState = <String, RTCDataChannelState>{};

  // Stats.
  final StatsAccumulator _stats = StatsAccumulator();

  /// Separate counters for the ~2 s health checks, so they do not disturb
  /// the 10 s quality samples.
  final StatsAccumulator _healthStats = StatsAccumulator();

  /// When the first health sample with a selected path was taken (bandwidth
  /// estimates ramp up after it).
  DateTime? firstPathAt;

  /// Key of the video encoding last applied with [applyVideo].
  String _videoKey = '';
  ConnectionType? _connectionType;
  ConnectionType? get connectionType => _connectionType;

  bool get isConnected =>
      _iceState == RTCIceConnectionState.RTCIceConnectionStateConnected ||
      _iceState == RTCIceConnectionState.RTCIceConnectionStateCompleted;

  /// Creates the peer connection and attaches local media. When [initiator],
  /// sends the first offer; missing local tracks are replaced by receive-only
  /// transceivers there so remote media still arrives.
  Future<void> start({
    required Map<String, dynamic> configuration,
    MediaStream? localStream,
    MediaStreamTrack? audioTrack,
    MediaStreamTrack? videoTrack,
    required bool receiveAudio,
    required bool receiveVideo,
  }) async {
    try {
      await _start(
        configuration: configuration,
        localStream: localStream,
        audioTrack: audioTrack,
        videoTrack: videoTrack,
        receiveAudio: receiveAudio,
        receiveVideo: receiveVideo,
      );
    } catch (e) {
      _reportError('peer_failed', 'Could not open a peer connection to ${peer.userId}: $e');
    } finally {
      if (!_started.isCompleted) _started.complete();
    }
  }

  Future<void> _start({
    required Map<String, dynamic> configuration,
    MediaStream? localStream,
    MediaStreamTrack? audioTrack,
    MediaStreamTrack? videoTrack,
    required bool receiveAudio,
    required bool receiveVideo,
  }) async {
    _receiveAudio = receiveAudio;
    _receiveVideo = receiveVideo;
    final RTCPeerConnection pc = await createPeerConnection(configuration);
    if (_closed) {
      await _disposePc(pc);
      return;
    }
    _pc = pc;

    pc.onIceCandidate = (RTCIceCandidate candidate) {
      final String? line = candidate.candidate;
      if (line == null || line.isEmpty) return; // end-of-candidates
      sendSignal(SignalData.iceCandidate(line, candidate.sdpMid, candidate.sdpMLineIndex));
    };
    pc.onTrack = (RTCTrackEvent event) {
      unawaited(_handleTrack(event));
    };
    pc.onIceConnectionState = (RTCIceConnectionState state) {
      _handleIceState(state);
    };
    pc.onConnectionState = (RTCPeerConnectionState state) {
      if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed) requestRestart();
    };
    pc.onDataChannel = (RTCDataChannel channel) {
      _adoptChannel(channel);
    };
    pc.onRenegotiationNeeded = () {
      // Before the first exchange the initial offer/answer already covers
      // the tracks added here; afterwards each event is honoured.
      if (!_initialDone || _closed) return;
      _requestNegotiation();
    };

    // One stream groups the audio and video tracks so the far side keeps
    // them in sync.
    final MediaStream? sendStream =
        (audioTrack != null || videoTrack != null) ? await _streamOrNew(localStream) : null;
    if (audioTrack != null && sendStream != null) {
      _audioSender = await pc.addTrack(audioTrack, sendStream);
      _hasAudioLine = true;
    }
    if (videoTrack != null && sendStream != null) {
      _videoSender = await pc.addTrack(videoTrack, sendStream);
      _hasVideoLine = true;
    }

    if (initiator) {
      // Created before the first offer, so it carries the data section.
      try {
        _adoptChannel(await pc.createDataChannel(kReliableChannelLabel, RTCDataChannelInit()..ordered = true));
        // The plugin drops `maxRetransmits: 0`, so 1 is the least it sends.
        _adoptChannel(await pc.createDataChannel(
            kUnreliableChannelLabel,
            RTCDataChannelInit()
              ..ordered = false
              ..maxRetransmits = 1));
      } catch (e) {
        _reportError('data_channel_failed', 'Could not open a data channel (messages go through the server): $e');
      }
      if (_closed) return;
      await _addReceiveOnlyLines(pc);
      _needsNegotiation = true;
      _scheduleRun();
    } else {
      // The newly joined peer should offer to us. If that never happens
      // (its offer was lost), offer ourselves.
      _answererTimer = Timer(_answererFallback, () {
        _answererTimer = null;
        if (_closed || _initialDone) return;
        _enqueue(() async {
          if (_closed || _initialDone) return;
          final RTCPeerConnection? p = _pc;
          if (p == null) return;
          await _addReceiveOnlyLines(p);
          _initialDone = true;
          _needsNegotiation = true;
          _scheduleRun();
        });
      });
    }
  }

  Future<void> _addReceiveOnlyLines(RTCPeerConnection pc) async {
    if (_receiveAudio && !_hasAudioLine) {
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      _hasAudioLine = true;
    }
    if (_receiveVideo && !_hasVideoLine) {
      await pc.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      _hasVideoLine = true;
    }
  }

  // ---------------------------------------------------------------------
  // Data channels (in-call messages)
  // ---------------------------------------------------------------------

  void _adoptChannel(RTCDataChannel ch) {
    if (_closed) return;
    final String label = ch.label ?? '';
    if (label == kReliableChannelLabel) {
      _reliableChannel = ch;
    } else if (label == kUnreliableChannelLabel) {
      _unreliableChannel = ch;
    } else {
      return; // not ours
    }
    final RTCDataChannelState? initial = ch.state;
    if (initial != null) _channelState[label] = initial;
    ch.onDataChannelState = (RTCDataChannelState state) {
      _channelState[label] = state;
    };
    ch.onMessage = (RTCDataChannelMessage message) {
      if (_closed || message.isBinary) return;
      // A channel adopted after it opened may never report its state.
      _channelState.putIfAbsent(label, () => RTCDataChannelState.RTCDataChannelOpen);
      final void Function(PeerSession, String)? cb = onChannelMessage;
      if (cb != null) cb(this, message.text);
    };
  }

  bool _isOpen(RTCDataChannel? ch) =>
      ch != null && (_channelState[ch.label ?? ''] ?? ch.state) == RTCDataChannelState.RTCDataChannelOpen;

  /// Whether a message can go to this peer over a data channel now.
  bool channelOpen({bool reliable = true}) {
    if (_closed) return false;
    return reliable ? _isOpen(_reliableChannel) : (_isOpen(_unreliableChannel) || _isOpen(_reliableChannel));
  }

  /// Sends one message over a data channel; false when it could not (use
  /// the server).
  Future<bool> sendOnChannel(String text, {bool reliable = true}) async {
    if (!channelOpen(reliable: reliable)) return false;
    final RTCDataChannel ch = (!reliable && _isOpen(_unreliableChannel)) ? _unreliableChannel! : _reliableChannel!;
    try {
      await ch.send(RTCDataChannelMessage(text));
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Serial operation chain
  // ---------------------------------------------------------------------

  void _enqueue(Future<void> Function() op) {
    _chain = _chain.then((void _) async {
      if (_closed) return;
      try {
        await op();
      } catch (e) {
        _reportError('negotiation_failed', 'WebRTC negotiation with ${peer.userId} failed: $e');
      }
    });
  }

  void _requestNegotiation({bool iceRestart = false}) {
    _needsNegotiation = true;
    if (iceRestart) _needsIceRestart = true;
    _scheduleRun();
  }

  void _scheduleRun() {
    if (_runScheduled) return;
    _runScheduled = true;
    _enqueue(() async {
      _runScheduled = false;
      await _negotiateIfNeeded();
    });
  }

  Future<void> _negotiateIfNeeded() async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _closed || !_needsNegotiation) return;
    if (_sigState != _stable) return; // re-checked when we are back to stable
    if (!initiator && !_initialDone) return; // wait for the remote offer
    final bool restart = _needsIceRestart;
    _needsNegotiation = false;
    _needsIceRestart = false;
    _makingOffer = true;
    try {
      final RTCSessionDescription offer =
          await pc.createOffer(restart ? _iceRestartConstraints : <String, dynamic>{});
      if (_closed) return;
      if (_sigState != _stable) {
        _needsNegotiation = true;
        if (restart) _needsIceRestart = true;
        return;
      }
      await pc.setLocalDescription(offer);
      _sigState = _haveLocalOffer;
      sendSignal(SignalData.description(offer.type ?? 'offer', offer.sdp ?? ''));
    } finally {
      _makingOffer = false;
    }
  }

  void _backToStable() {
    _sigState = _stable;
    if (_needsNegotiation) _scheduleRun();
    // An ICE restart over a path that never broke keeps the ICE state
    // "connected" (no state event): it is done once negotiated.
    _finishRestartIfConnected();
  }

  /// Ends a restart (fires [onReconnected]) when the path is up and no
  /// negotiation is pending.
  void _finishRestartIfConnected() {
    if (_closed || !_restarting || !isConnected) return;
    if (_sigState != _stable || _needsNegotiation) return;
    _restartCheckTimer?.cancel();
    _restartCheckTimer = null;
    _restarting = false;
    _restartAttempt = 0;
    _restartBackoff.reset();
    final void Function(PeerSession)? cb = onReconnected;
    if (cb != null) cb(this);
  }

  // ---------------------------------------------------------------------
  // Incoming signals
  // ---------------------------------------------------------------------

  /// Handles a `signal` from this peer.
  void handleSignal(SignalData data) {
    if (_closed || data.isEmpty) return;
    _enqueue(() => _handleSignal(data));
  }

  Future<void> _handleSignal(SignalData data) async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _closed) return;

    final SdpPayload? sdp = data.sdp;
    if (sdp != null) {
      await _handleDescription(pc, sdp);
      return;
    }

    final CandidatePayload? cand = data.candidate;
    if (cand != null) {
      final RTCIceCandidate candidate = RTCIceCandidate(cand.candidate, cand.sdpMid, cand.sdpMLineIndex);
      if (!_remoteDescriptionSet) {
        _pendingCandidates.add(candidate);
        return;
      }
      try {
        await pc.addCandidate(candidate);
      } catch (e) {
        // Candidates of an offer we ignored (glare) are expected to fail.
        if (!_ignoreOffer) {
          _reportError('signal_failed', 'Could not add an ICE candidate from ${peer.userId}: $e');
        }
      }
      return;
    }

    if (data.restart) {
      // The other side lost the path and asks for an ICE restart.
      restartNow(offer: true);
    }
  }

  Future<void> _handleDescription(RTCPeerConnection pc, SdpPayload sdp) async {
    final bool isOffer = sdp.type == 'offer';
    if (!isOffer && sdp.type != 'answer') return;

    final bool collision = isOffer && (_makingOffer || _sigState != _stable);
    _ignoreOffer = !polite && collision;
    if (_ignoreOffer) return; // impolite: our offer wins, theirs is dropped

    if (!isOffer && _sigState != _haveLocalOffer) {
      return; // stale answer (e.g. to an offer we rolled back)
    }

    if (collision) {
      // Polite: roll back our pending offer, then take theirs. If explicit
      // rollback is refused, setRemoteDescription(offer) still performs an
      // implicit rollback in current libwebrtc.
      try {
        await pc.setLocalDescription(RTCSessionDescription('', 'rollback'));
      } catch (_) {}
      _sigState = _stable;
      // Whatever our rolled-back offer wanted is offered again afterwards.
      _needsNegotiation = true;
    }

    if (isOffer) {
      _answererTimer?.cancel();
      _answererTimer = null;
      if (!_initialDone) {
        // Events fired by start()'s addTrack calls are covered by answering.
        if (!collision) _needsNegotiation = false;
        _initialDone = true;
      }
      await pc.setRemoteDescription(RTCSessionDescription(sdp.sdp, sdp.type));
      _remoteDescriptionSet = true;
      _sigState = _haveRemoteOffer;
      await _flushCandidates(pc);
      final RTCSessionDescription answer = await pc.createAnswer(<String, dynamic>{});
      await pc.setLocalDescription(answer);
      sendSignal(SignalData.description(answer.type ?? 'answer', answer.sdp ?? ''));
      _backToStable();
    } else {
      _initialDone = true;
      await pc.setRemoteDescription(RTCSessionDescription(sdp.sdp, sdp.type));
      _remoteDescriptionSet = true;
      await _flushCandidates(pc);
      _backToStable();
    }
  }

  Future<void> _flushCandidates(RTCPeerConnection pc) async {
    if (_pendingCandidates.isEmpty) return;
    final List<RTCIceCandidate> list = List<RTCIceCandidate>.from(_pendingCandidates);
    _pendingCandidates.clear();
    for (final RTCIceCandidate c in list) {
      try {
        await pc.addCandidate(c);
      } catch (_) {
        // A stale candidate (from an ignored offer or before a restart).
      }
    }
  }

  // ---------------------------------------------------------------------
  // Remote media
  // ---------------------------------------------------------------------

  Future<void> _handleTrack(RTCTrackEvent event) async {
    if (_closed) return;
    final MediaStreamTrack track = event.track;
    MediaStream? stream;
    if (event.streams.isNotEmpty) {
      stream = event.streams.first;
    } else {
      // A track without a stream (sender used addTrack without one).
      try {
        final MediaStream s = _remoteStream ?? await createLocalMediaStream('catz-remote-${peer.pid}');
        await s.addTrack(track);
        stream = s;
      } catch (e) {
        _reportError('remote_track_failed', 'Could not attach a remote track: $e');
        return;
      }
    }
    _remoteStream = stream;
    final void Function(PeerSession, MediaStream, MediaStreamTrack)? cb = onRemoteStream;
    if (cb != null) cb(this, stream, track);
  }

  // ---------------------------------------------------------------------
  // ICE recovery
  // ---------------------------------------------------------------------

  void _handleIceState(RTCIceConnectionState state) {
    _iceState = state;
    if (_closed) return;
    if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
        state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      _disconnectTimer?.cancel();
      _disconnectTimer = null;
      _restartCheckTimer?.cancel();
      _restartCheckTimer = null;
      _everConnected = true;
      _restartWanted = false;
      if (_restarting) {
        _restarting = false;
        _restartAttempt = 0;
        _restartBackoff.reset();
        final void Function(PeerSession)? cb = onReconnected;
        if (cb != null) cb(this);
      }
      // Learn the path (direct / relay) right away.
      unawaited(sampleStats());
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected) {
      // Often recovers by itself (a short Wi-Fi blip); restart if it lasts.
      _disconnectTimer ??= Timer(_disconnectedGrace, () {
        _disconnectTimer = null;
        if (_iceState == RTCIceConnectionState.RTCIceConnectionStateDisconnected) requestRestart();
      });
    } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed) {
      requestRestart();
    }
  }

  /// Schedules an ICE restart with backoff (the first one at once).
  void requestRestart() {
    if (_closed || _restartTimer != null) return;
    final Duration delay = _restartAttempt == 0 ? Duration.zero : _restartBackoff.next();
    _restartTimer = Timer(delay, () {
      _restartTimer = null;
      _doRestart();
    });
  }

  /// Restarts ICE right away (network changed, or the peer asked). With
  /// [offer] this side makes the restart offer even when it is not the
  /// initiator (used when the peer explicitly asked, so requests never
  /// bounce back and forth).
  void restartNow({bool offer = false}) {
    if (_closed) return;
    _restartTimer?.cancel();
    _restartTimer = null;
    _doRestart(offer: offer);
  }

  void _doRestart({bool offer = false}) {
    if (_closed) return;
    if (!canSignal()) {
      // Offers cannot travel now; do it when signaling is back.
      _restartWanted = true;
      return;
    }
    _restartWanted = false;
    _restartAttempt++;
    _restarting = true;
    final void Function(PeerSession, int)? cb = onReconnecting;
    if (cb != null) cb(this, _restartAttempt);

    if ((initiator || offer) && (initiator || _remoteDescriptionSet)) {
      // Our next offer carries new ICE credentials.
      _requestNegotiation(iceRestart: true);
    } else {
      // The initiator drives restarts: ask it.
      sendSignal(SignalData.restartRequest());
    }

    _restartCheckTimer?.cancel();
    _restartCheckTimer = Timer(_restartCheck, () {
      _restartCheckTimer = null;
      if (_closed) return;
      if (isConnected) {
        _finishRestartIfConnected();
        return;
      }
      requestRestart();
    });
  }

  /// The network changed (Wi-Fi <-> cellular, back online): restart
  /// proactively once a path existed.
  void onNetworkChange() {
    if (_closed || !_everConnected) return;
    if (initiator) {
      restartNow();
    } else if (canSignal()) {
      sendSignal(SignalData.restartRequest());
    }
  }

  /// Called by the client when the signaling socket is back.
  void onSignalingRestored() {
    if (_closed) return;
    final bool broken = _iceState == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
        _iceState == RTCIceConnectionState.RTCIceConnectionStateFailed;
    if (_restartWanted || broken) restartNow();
  }

  /// Applies fresh ICE servers (TURN credentials) without renegotiating.
  Future<void> setConfiguration(Map<String, dynamic> configuration) async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _closed) return;
    try {
      await pc.setConfiguration(configuration);
    } catch (e) {
      _reportError('ice_refresh_failed', 'Could not apply new ICE servers: $e');
    }
  }

  // ---------------------------------------------------------------------
  // Local media changes
  // ---------------------------------------------------------------------

  /// `addTrack` needs a stream to group the track in; when the caller has
  /// none, a fresh local stream is created for it.
  Future<MediaStream> _streamOrNew(MediaStream? stream) async =>
      stream ?? await createLocalMediaStream('catz-local');

  /// Sends [track] as this peer's video (camera or screen); `null` stops
  /// sending video. With no video sender yet, adds one (renegotiates).
  Future<void> setVideoTrack(MediaStreamTrack? track, MediaStream? stream) async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _closed) return;
    final RTCRtpSender? sender = _videoSender;
    if (sender != null) {
      await sender.replaceTrack(track);
      return;
    }
    if (track == null) return;
    _videoSender = await pc.addTrack(track, await _streamOrNew(stream));
    _hasVideoLine = true;
  }

  /// Same as [setVideoTrack] for audio.
  Future<void> setAudioTrack(MediaStreamTrack? track, MediaStream? stream) async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _closed) return;
    final RTCRtpSender? sender = _audioSender;
    if (sender != null) {
      await sender.replaceTrack(track);
      return;
    }
    if (track == null) return;
    _audioSender = await pc.addTrack(track, await _streamOrNew(stream));
    _hasAudioLine = true;
  }

  // ---------------------------------------------------------------------
  // Stats
  // ---------------------------------------------------------------------

  /// Reads `getStats()` and updates the connection type (emitting
  /// [onConnectionType] on change). Null when stats are unavailable.
  /// [health] uses the separate counters of the ~2 s health checks.
  Future<StatsSample?> sampleStats({bool health = false}) async {
    final RTCPeerConnection? pc = _pc;
    if (pc == null || _closed) return null;
    final List<StatsReport> reports;
    try {
      reports = await pc.getStats();
    } catch (_) {
      return null;
    }
    if (_closed) return null;
    final List<StatsEntry> entries = <StatsEntry>[];
    for (final StatsReport r in reports) {
      final Map<String, dynamic> values = <String, dynamic>{};
      r.values.forEach((dynamic k, dynamic v) {
        if (k != null) values[k.toString()] = v;
      });
      entries.add(StatsEntry(id: r.id, type: r.type, values: values));
    }
    final DateTime now = DateTime.now();
    final StatsSample sample = (health ? _healthStats : _stats).add(entries, now);
    if (health && sample.connection != null) firstPathAt ??= now;
    final ConnectionType? type = sample.connection;
    if (type != null && type != _connectionType) {
      _connectionType = type;
      final void Function(PeerSession, ConnectionType)? cb = onConnectionType;
      if (cb != null) cb(this, type);
    }
    return sample;
  }

  /// True when this peer has a video sender with a track.
  bool get sendsVideo => _videoSender?.track != null;

  /// Sets the outgoing video encoding on the video sender (never audio):
  /// `maxBitrate`, `scaleResolutionDownBy` and `active` (false pauses video
  /// without dropping the track, so resuming is instant and needs no
  /// renegotiation). Does nothing when unchanged. Returns false when it
  /// could not be applied yet (e.g. before negotiation) — try again later.
  Future<bool> applyVideo(VideoTarget target) async {
    if (_closed || _pc == null) return false;
    final RTCRtpSender? sender = _videoSender;
    if (sender == null || sender.track == null) return true; // nothing to shape
    final String key = '${target.key}|${sender.senderId}';
    if (key == _videoKey) return true;
    // Never shaped and the target is the platform default: leave it alone.
    if (_videoKey.isEmpty && target.isDefault) return true;
    try {
      final RTCRtpParameters params = sender.parameters;
      final List<RTCRtpEncoding>? encodings = params.encodings;
      if (encodings == null || encodings.isEmpty) return false; // not negotiated yet
      final RTCRtpEncoding e = encodings.first;
      final double? kbps = target.maxBitrateKbps;
      e.maxBitrate = kbps == null ? null : (kbps * 1000).round();
      e.scaleResolutionDownBy = target.scaleResolutionDownBy < 1 ? 1.0 : target.scaleResolutionDownBy;
      e.active = target.active;
      final bool ok = await sender.setParameters(params);
      if (ok) _videoKey = key;
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ---------------------------------------------------------------------
  // Teardown
  // ---------------------------------------------------------------------

  void _reportError(String code, String message) {
    final void Function(PeerSession, CallError)? cb = onError;
    if (cb != null) cb(this, CallError(code, message, callId: callId));
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final Timer? t in <Timer?>[_disconnectTimer, _restartTimer, _restartCheckTimer, _answererTimer]) {
      t?.cancel();
    }
    _disconnectTimer = null;
    _restartTimer = null;
    _restartCheckTimer = null;
    _answererTimer = null;
    _pendingCandidates.clear();
    if (!_started.isCompleted) _started.complete();
    for (final RTCDataChannel? ch in <RTCDataChannel?>[_reliableChannel, _unreliableChannel]) {
      if (ch == null) continue;
      ch.onMessage = null;
      ch.onDataChannelState = null;
      try {
        await ch.close();
      } catch (_) {}
    }
    _reliableChannel = null;
    _unreliableChannel = null;
    _channelState.clear();
    final RTCPeerConnection? pc = _pc;
    _pc = null;
    if (pc != null) await _disposePc(pc);
  }

  static Future<void> _disposePc(RTCPeerConnection pc) async {
    pc.onIceCandidate = null;
    pc.onTrack = null;
    pc.onIceConnectionState = null;
    pc.onConnectionState = null;
    pc.onRenegotiationNeeded = null;
    pc.onDataChannel = null;
    try {
      await pc.close();
    } catch (_) {}
    try {
      await pc.dispose();
    } catch (_) {}
  }
}
