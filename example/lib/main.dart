// Minimal Catz Connect call app: paste a user token (from your backend's
// `calls.token(userId)`) and a call id (from `calls.create(...)`), join,
// and see local + remote video. Incoming calls for this user ring here too.

import 'dart:async';

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter/material.dart';

void main() => runApp(const CallExampleApp());

class CallExampleApp extends StatelessWidget {
  const CallExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Catz Connect calls',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      home: const CallPage(),
    );
  }
}

class CallPage extends StatefulWidget {
  const CallPage({super.key});

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final TextEditingController _url = TextEditingController(text: kDefaultCallsUrl);
  final TextEditingController _token = TextEditingController();
  final TextEditingController _callId = TextEditingController();

  CatzCallClient? _client;
  final List<StreamSubscription<dynamic>> _subs = <StreamSubscription<dynamic>>[];
  final RTCVideoRenderer _localRenderer = RTCVideoRenderer();
  final Map<String, RTCVideoRenderer> _remoteRenderers = <String, RTCVideoRenderer>{};
  final Map<String, String> _peerLabels = <String, String>{};
  final List<String> _log = <String>[];

  bool _video = true;
  bool _inCall = false;
  bool _busy = false;
  bool _micMuted = false;
  bool _camMuted = false;
  IncomingCall? _ringing;

  @override
  void initState() {
    super.initState();
    unawaited(_localRenderer.initialize());
  }

  @override
  void dispose() {
    unawaited(_shutdownClient());
    _localRenderer.dispose();
    for (final RTCVideoRenderer r in _remoteRenderers.values) {
      r.dispose();
    }
    _url.dispose();
    _token.dispose();
    _callId.dispose();
    super.dispose();
  }

  void _say(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 50) _log.removeLast();
    });
  }

  Future<CatzCallClient> _ensureClient() async {
    final CatzCallClient? existing = _client;
    if (existing != null) return existing;
    final String token = _token.text.trim();
    if (token.isEmpty) throw const CallError('no_token', 'Paste a user token first.');
    final CatzCallClient c = CatzCallClient(token: token, url: _url.text.trim());
    _client = c;
    _subs.addAll(<StreamSubscription<dynamic>>[
      c.incoming.listen((IncomingCall call) {
        if (!mounted) return;
        setState(() => _ringing = call);
        _say('Incoming ${call.mode.name} call from ${call.from}');
      }),
      c.state.listen((CallStateEvent e) {
        _say('Call ${e.callId}: ${e.status.name}${e.reason != null ? ' (${e.reason})' : ''}');
        if (e.status.isFinal) {
          if (mounted && _ringing?.callId == e.callId) setState(() => _ringing = null);
          if (c.callId == null) unawaited(_clearCallUi());
        }
      }),
      c.localStream.listen((LocalStreamEvent e) {
        if (!mounted) return;
        setState(() => _localRenderer.srcObject = e.stream);
      }),
      c.remoteStreams.listen((RemoteStreamEvent e) async {
        final String pid = e.peer.pid;
        RTCVideoRenderer? known = _remoteRenderers[pid];
        if (known == null) {
          final RTCVideoRenderer created = RTCVideoRenderer();
          await created.initialize();
          _remoteRenderers[pid] = created;
          known = created;
        }
        final RTCVideoRenderer renderer = known;
        if (e.peer.userId.isNotEmpty) _peerLabels[pid] = e.peer.userId;
        if (!mounted) return;
        setState(() => renderer.srcObject = e.stream);
      }),
      c.peerJoined.listen((PeerJoinedEvent e) => _say('${e.peer.userId} joined')),
      c.peerLeft.listen((PeerLeftEvent e) {
        _say('${e.peer.userId} left${e.reason != null ? ' (${e.reason})' : ''}');
        final RTCVideoRenderer? r = _remoteRenderers.remove(e.peer.pid);
        _peerLabels.remove(e.peer.pid);
        if (r != null) {
          r.srcObject = null;
          unawaited(r.dispose());
        }
        if (mounted) setState(() {});
      }),
      c.connection.listen((ConnectionEvent e) => _say('Path to ${e.peer.userId}: ${e.type.name}')),
      c.quality.listen((CallQuality q) => _say(
          'Quality ${q.peer.userId}: ${q.level.name}, rtt ${q.rttMs?.round()} ms, loss ${q.lossPct?.toStringAsFixed(1)} %')),
      c.reconnecting.listen((ReconnectingEvent e) => _say('Reconnecting ${e.scope.name} (attempt ${e.attempt})')),
      c.reconnected.listen((ReconnectedEvent e) => _say('Reconnected ${e.scope.name}')),
      c.provider.listen((ProviderEvent e) =>
          _say('Call runs on ${e.provider.name}: hand off to that SDK (room ${e.provider.room})')),
      c.errors.listen((CallError e) => _say('Error ${e.code}: ${e.message}')),
    ]);
    await c.connect();
    _say('Connected');
    return c;
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } on CallError catch (e) {
      _say('Error ${e.code}: ${e.message}');
    } catch (e) {
      _say('Error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _join() => _run(() async {
        final String id = _callId.text.trim();
        if (id.isEmpty) throw const CallError('bad_request', 'Enter a call id.');
        final CatzCallClient c = await _ensureClient();
        final JoinResult r = await c.join(id, audio: true, video: _video);
        setState(() => _inCall = true);
        _say('Joined ${r.call.id} as ${r.pid ?? '?'} with ${r.peers.length} peer(s)');
      });

  Future<void> _accept() => _run(() async {
        final IncomingCall? call = _ringing;
        final CatzCallClient? c = _client;
        if (call == null || c == null) return;
        setState(() => _ringing = null);
        _callId.text = call.callId;
        await c.accept(call.callId, audio: true, video: call.mode == CallMode.video);
        setState(() => _inCall = true);
      });

  Future<void> _decline() => _run(() async {
        final IncomingCall? call = _ringing;
        final CatzCallClient? c = _client;
        if (call == null || c == null) return;
        setState(() => _ringing = null);
        await c.decline(call.callId);
      });

  Future<void> _hangUp() => _run(() async {
        await _client?.leave();
        await _clearCallUi();
      });

  Future<void> _clearCallUi() async {
    for (final RTCVideoRenderer r in _remoteRenderers.values) {
      r.srcObject = null;
      await r.dispose();
    }
    _remoteRenderers.clear();
    _peerLabels.clear();
    if (!mounted) return;
    setState(() {
      _inCall = false;
      _micMuted = false;
      _camMuted = false;
      _localRenderer.srcObject = null;
    });
  }

  Future<void> _shutdownClient() async {
    for (final StreamSubscription<dynamic> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    final CatzCallClient? c = _client;
    _client = null;
    if (c != null) await c.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final CatzCallClient? c = _client;
    return Scaffold(
      appBar: AppBar(title: const Text('Catz Connect calls')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            if (!_inCall) _setupForm(),
            if (_ringing != null) _ringingBanner(_ringing!),
            Expanded(child: _videoGrid()),
            if (_inCall && c != null) _controls(c),
            SizedBox(
              height: 120,
              child: ListView.builder(
                reverse: false,
                itemCount: _log.length,
                itemBuilder: (BuildContext context, int i) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
                  child: Text(_log[i], style: Theme.of(context).textTheme.bodySmall),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setupForm() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: <Widget>[
          TextField(controller: _url, decoration: const InputDecoration(labelText: 'Signaling URL')),
          TextField(
            controller: _token,
            decoration: const InputDecoration(labelText: 'User token (ct1.…) from calls.token'),
          ),
          TextField(controller: _callId, decoration: const InputDecoration(labelText: 'Call id')),
          Row(
            children: <Widget>[
              Switch(value: _video, onChanged: (bool v) => setState(() => _video = v)),
              const Text('Video'),
              const Spacer(),
              OutlinedButton(
                onPressed: _busy
                    ? null
                    : () => _run(() async {
                          await _ensureClient();
                        }),
                child: const Text('Connect only'),
              ),
              const SizedBox(width: 8),
              FilledButton(onPressed: _busy ? null : _join, child: const Text('Join')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _ringingBanner(IncomingCall call) {
    return MaterialBanner(
      content: Text('${call.from} is calling (${call.mode.name})'),
      actions: <Widget>[
        TextButton(onPressed: _decline, child: const Text('Decline')),
        FilledButton(onPressed: _accept, child: const Text('Accept')),
      ],
    );
  }

  Widget _videoGrid() {
    final List<Widget> tiles = <Widget>[
      _tile('You', RTCVideoView(_localRenderer, mirror: true, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover)),
      for (final MapEntry<String, RTCVideoRenderer> e in _remoteRenderers.entries)
        _tile(
          _peerLabels[e.key]?.isNotEmpty == true ? _peerLabels[e.key]! : e.key,
          RTCVideoView(e.value, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
        ),
    ];
    return GridView.count(
      crossAxisCount: tiles.length > 1 ? 2 : 1,
      padding: const EdgeInsets.all(8),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      children: tiles,
    );
  }

  Widget _tile(String label, Widget video) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          const ColoredBox(color: Colors.black87),
          video,
          Positioned(
            left: 8,
            bottom: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: Colors.black54,
              child: Text(label, style: const TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _controls(CatzCallClient c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: <Widget>[
          IconButton.filledTonal(
            tooltip: _micMuted ? 'Unmute' : 'Mute',
            icon: Icon(_micMuted ? Icons.mic_off : Icons.mic),
            onPressed: () => _run(() async {
              final bool next = !_micMuted;
              await c.setMuted(MediaKind.audio, next);
              setState(() => _micMuted = next);
            }),
          ),
          IconButton.filledTonal(
            tooltip: _camMuted ? 'Camera on' : 'Camera off',
            icon: Icon(_camMuted ? Icons.videocam_off : Icons.videocam),
            onPressed: () => _run(() async {
              final bool next = !_camMuted;
              await c.setMuted(MediaKind.video, next);
              setState(() => _camMuted = next);
            }),
          ),
          IconButton.filledTonal(
            tooltip: 'Switch camera',
            icon: const Icon(Icons.cameraswitch),
            onPressed: () => _run(() async {
              await c.switchCamera();
            }),
          ),
          IconButton.filled(
            tooltip: 'Hang up',
            style: IconButton.styleFrom(backgroundColor: Colors.red),
            icon: const Icon(Icons.call_end),
            onPressed: _hangUp,
          ),
        ],
      ),
    );
  }
}
