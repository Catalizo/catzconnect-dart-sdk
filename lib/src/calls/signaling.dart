// One logical signaling connection over as many WebSockets as it takes:
// reconnects with exponential backoff and jitter, fetches a fresh token when
// the old one expires or is refused, answers pings, detects a dead socket
// after 45 s of silence and queues frames while it is down.
// (Behaviour matches the browser SDK's `Signaling` class.)

import 'dart:async';
import 'dart:math' as math;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'backoff.dart';
import 'models.dart';
import 'protocol.dart';

/// Opens a WebSocket for a URI. Replaceable for tests.
typedef SocketConnector = WebSocketChannel Function(Uri uri);

WebSocketChannel _defaultConnector(Uri uri) => WebSocketChannel.connect(uri);

class SignalingSocket {
  SignalingSocket({
    required this.url,
    String? token,
    this.getToken,
    SocketConnector? connector,
    math.Random? random,
    this.firstConnectTimeout = const Duration(seconds: 20),
    this.openTimeout = const Duration(seconds: 15),
    this.silenceTimeout = const Duration(seconds: 45),
    this.maxQueue = 500,
  })  : _token = token,
        _connector = connector ?? _defaultConnector,
        _backoff = Backoff(
          initialDelay: const Duration(milliseconds: 500),
          maxDelay: const Duration(seconds: 15),
          jitter: 0.5,
          random: random,
        );

  final String url;
  final Future<String> Function()? getToken;
  final Duration firstConnectTimeout;
  final Duration openTimeout;
  final Duration silenceTimeout;
  final int maxQueue;

  final SocketConnector _connector;
  final Backoff _backoff;

  /// Every server frame except `ping` (answered here) and `hello` (see
  /// [onOpen]).
  void Function(ServerMessage message)? onMessage;

  /// A socket said hello; `reconnect` is false for the first one. Queued
  /// frames are flushed right after this returns, and [send] with
  /// `force: true` writes ahead of them (used for `resume`).
  void Function(HelloMessage hello, bool reconnect)? onOpen;

  /// The socket dropped after having been open; a reconnect is scheduled.
  void Function(int attempt, Duration delay)? onDown;

  /// No way to carry on (no usable token). The socket is closed for good.
  void Function(CallError error)? onFatal;

  String? _token;
  bool _tokenStale = false;
  int _failuresBeforeHello = 0;
  bool _everOpened = false;
  bool _ready = false; // hello received on the current socket
  bool _closed = false;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _sub;
  bool _saidHello = false;
  DateTime _lastRx = DateTime.now();
  Timer? _retryTimer;
  Timer? _watchdog;
  Timer? _openTimer;
  Completer<HelloMessage>? _firstConnect;
  Timer? _firstConnectTimer;
  final List<ClientMessage> _queue = <ClientMessage>[];

  HelloMessage? _hello;

  /// The last `hello` received.
  HelloMessage? get hello => _hello;

  /// True while a socket is open and has said hello.
  bool get isOpen => _ready;
  bool get isClosed => _closed;

  /// Opens the first socket and resolves on the server's `hello`. Retries
  /// with backoff for up to [firstConnectTimeout], then throws a
  /// [CallError] with code `connect_failed` (or the fatal error's code).
  Future<HelloMessage> connect() {
    if (_closed) {
      return Future<HelloMessage>.error(const CallError('closed', 'The call client is closed.'));
    }
    final HelloMessage? h = _hello;
    if (_ready && h != null) return Future<HelloMessage>.value(h);
    final Completer<HelloMessage>? pending = _firstConnect;
    if (pending != null) return pending.future;
    final Completer<HelloMessage> c = Completer<HelloMessage>();
    _firstConnect = c;
    if (_everOpened) {
      // Already in its reconnect loop: wait for the next hello.
      reconnectNow();
      return c.future;
    }
    _firstConnectTimer = Timer(firstConnectTimeout, () {
      final Completer<HelloMessage>? fc = _firstConnect;
      if (fc == null || fc.isCompleted) return;
      _firstConnect = null;
      unawaited(close());
      fc.completeError(const CallError('connect_failed', 'Could not reach the signaling server.'));
    });
    unawaited(_openSocket());
    return c.future;
  }

  /// Sends now when open; otherwise queues it (unless the frame is not
  /// queueable: pong, stats, resume). With [force] the frame is written to
  /// a socket that already said hello, before the queue is flushed.
  bool send(ClientMessage message, {bool force = false}) {
    if (_closed) return false;
    final WebSocketChannel? ch = _channel;
    if (ch != null && (_ready || (force && _saidHello))) {
      if (_write(ch, message)) return true;
    }
    if (!message.queueable) return false;
    _queue.add(message);
    if (_queue.length > maxQueue) _queue.removeAt(0);
    return false;
  }

  /// Drops queued frames that [drop] matches (e.g. signals of an ended call).
  void dropQueued(bool Function(ClientMessage m) drop) {
    _queue.removeWhere(drop);
  }

  /// Skips the backoff and reconnects now (e.g. the network came back).
  void reconnectNow() {
    if (_closed || _channel != null) return;
    final Timer? t = _retryTimer;
    if (t == null) return;
    t.cancel();
    _retryTimer = null;
    unawaited(_openSocket());
  }

  /// The server refused the token: fetch a new one before the next attempt.
  void markTokenStale() {
    _tokenStale = true;
  }

  bool _write(WebSocketChannel ch, ClientMessage message) {
    final String text = message.encode();
    if (text.length > kMaxFrameBytes) return true; // never deliverable; drop it
    try {
      ch.sink.add(text);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<String?> _ensureToken() async {
    final String? current = _token;
    final int? exp = current == null ? null : tokenExpiry(current);
    final double nowS = DateTime.now().millisecondsSinceEpoch / 1000.0;
    final bool expiringSoon = exp != null && exp - nowS < 30;
    final bool needNew = current == null || _tokenStale || expiringSoon || _failuresBeforeHello >= 2;
    final Future<String> Function()? fetch = getToken;

    if (needNew && fetch != null) {
      try {
        final String t = await fetch();
        if (t.isEmpty) throw StateError('getToken() returned an empty token');
        _token = t;
        _tokenStale = false;
        _failuresBeforeHello = 0;
        return t;
      } catch (e) {
        // Treated like a network failure: try again with backoff.
        _emit(ErrorMessage.fromJson(<String, dynamic>{
          't': 'error',
          'code': 'token_fetch_failed',
          'message': 'getToken() failed: $e',
        }));
        return null;
      }
    }
    if (current == null) {
      _fatal('no_token', 'Pass a token or getToken to CatzCallClient.');
      return null;
    }
    if (_tokenStale || (exp != null && exp <= nowS)) {
      _fatal('token_expired', 'The call token expired or was refused; pass getToken to renew it automatically.');
      return null;
    }
    return current;
  }

  Future<void> _openSocket() async {
    if (_closed) return;
    final String? token = await _ensureToken();
    if (_closed) return;
    if (token == null) {
      _scheduleReconnect();
      return;
    }

    final WebSocketChannel ch;
    try {
      ch = _connector(buildSocketUri(url, token));
    } catch (e) {
      _emit(ErrorMessage.fromJson(<String, dynamic>{
        't': 'error',
        'code': 'signaling_failed',
        'message': 'Could not open the signaling socket: $e',
      }));
      _scheduleReconnect();
      return;
    }
    _channel = ch;
    _saidHello = false;
    _ready = false;
    _lastRx = DateTime.now();
    _sub = ch.stream.listen(
      (dynamic data) => _onData(ch, data),
      onError: (Object error) => _onClosed(ch),
      onDone: () => _onClosed(ch),
      cancelOnError: true,
    );
    // A socket that neither fails nor says hello in time is dropped.
    _openTimer?.cancel();
    _openTimer = Timer(openTimeout, () {
      if (identical(_channel, ch) && !_saidHello) _onClosed(ch, forceClose: true);
    });
    try {
      await ch.ready;
    } catch (_) {
      _onClosed(ch);
    }
  }

  void _onData(WebSocketChannel ch, dynamic data) {
    if (!identical(ch, _channel)) return;
    _lastRx = DateTime.now();
    if (data is! String) return; // the protocol uses text frames only
    final ServerMessage msg;
    try {
      msg = ServerMessage.decode(data);
    } catch (_) {
      return;
    }

    if (msg is PingMessage) {
      _write(ch, ClientMessage.pong(msg.ts));
      return;
    }
    if (msg is HelloMessage) {
      _onHello(ch, msg);
      return;
    }
    if (msg is ErrorMessage && msg.error.callId == null && isAuthErrorCode(msg.error.code)) {
      _tokenStale = true;
    }
    _emit(msg);
  }

  void _onHello(WebSocketChannel ch, HelloMessage msg) {
    _saidHello = true;
    _openTimer?.cancel();
    _openTimer = null;
    final bool reconnect = _everOpened;
    _everOpened = true;
    _hello = msg;
    _backoff.reset();
    _failuresBeforeHello = 0;
    _startWatchdog();
    final Completer<HelloMessage>? fc = _firstConnect;
    _firstConnect = null;
    _firstConnectTimer?.cancel();
    _firstConnectTimer = null;
    final void Function(HelloMessage, bool)? cb = onOpen;
    if (cb != null) {
      try {
        cb(msg, reconnect);
      } catch (_) {}
    }
    _ready = identical(ch, _channel);
    _flush();
    if (fc != null && !fc.isCompleted) fc.complete(msg);
  }

  void _emit(ServerMessage msg) {
    final void Function(ServerMessage)? cb = onMessage;
    if (cb == null) return;
    try {
      cb(msg);
    } catch (_) {}
  }

  void _flush() {
    final List<ClientMessage> q = List<ClientMessage>.from(_queue);
    _queue.clear();
    for (final ClientMessage m in q) {
      send(m);
    }
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _watchdog = Timer.periodic(const Duration(seconds: 5), (Timer t) {
      final WebSocketChannel? ch = _channel;
      if (ch == null) return;
      if (DateTime.now().difference(_lastRx) > silenceTimeout) {
        // Silent for 45 s (half-open TCP after a network switch): reconnect.
        _onClosed(ch, forceClose: true);
      }
    });
  }

  void _onClosed(WebSocketChannel ch, {bool forceClose = false}) {
    if (!identical(ch, _channel)) return;
    final int? code = ch.closeCode;
    _channel = null;
    _ready = false;
    _watchdog?.cancel();
    _watchdog = null;
    _openTimer?.cancel();
    _openTimer = null;
    final StreamSubscription<dynamic>? sub = _sub;
    _sub = null;
    if (sub != null) unawaited(sub.cancel());
    if (forceClose) _closeChannel(ch, 4000);
    if (_closed) return;
    if (!_saidHello) _failuresBeforeHello += 1;
    if (isAuthCloseCode(code)) _tokenStale = true;
    // Rate limited / overloaded (4008): the token is fine, back off harder.
    if (code == kOverloadCloseCode) _backoff.atLeast(3);
    _scheduleReconnect();
  }

  void _closeChannel(WebSocketChannel ch, int code) {
    try {
      unawaited(ch.sink.close(code).then((dynamic _) {}, onError: (Object _) {}));
    } catch (_) {}
  }

  void _scheduleReconnect() {
    if (_closed || _retryTimer != null) return;
    final Duration delay = _backoff.next();
    if (_everOpened) {
      final void Function(int, Duration)? cb = onDown;
      if (cb != null) {
        try {
          cb(_backoff.attempt, delay);
        } catch (_) {}
      }
    }
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(_openSocket());
    });
  }

  void _fatal(String code, String message) {
    final CallError err = CallError(code, message);
    final Completer<HelloMessage>? fc = _firstConnect;
    _firstConnect = null;
    unawaited(close());
    if (fc != null && !fc.isCompleted) fc.completeError(err);
    final void Function(CallError)? cb = onFatal;
    if (cb != null) {
      try {
        cb(err);
      } catch (_) {}
    }
  }

  /// Closes the socket for good.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _ready = false;
    _queue.clear();
    _retryTimer?.cancel();
    _retryTimer = null;
    _watchdog?.cancel();
    _watchdog = null;
    _openTimer?.cancel();
    _openTimer = null;
    _firstConnectTimer?.cancel();
    _firstConnectTimer = null;
    final StreamSubscription<dynamic>? sub = _sub;
    _sub = null;
    final WebSocketChannel? ch = _channel;
    _channel = null;
    if (sub != null) unawaited(sub.cancel());
    if (ch != null) _closeChannel(ch, 1000);
    final Completer<HelloMessage>? fc = _firstConnect;
    _firstConnect = null;
    if (fc != null && !fc.isCompleted) {
      fc.completeError(const CallError('closed', 'The call client is closed.'));
    }
  }
}
