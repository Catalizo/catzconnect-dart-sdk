import 'dart:math' as math;

/// Exponential backoff with random jitter, used for signaling reconnects and
/// ICE restarts.
///
/// Delay for attempt n (0-based) is d = `initialDelay * factor^n`, capped at
/// [maxDelay], then reduced by a random fraction of up to [jitter]: the
/// result lies in `[d * (1 - jitter), d]`. With the defaults (500 ms, x2,
/// 15 s, jitter 0.5) this is the browser SDK's "[d/2, d]" backoff.
class Backoff {
  Backoff({
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 15),
    this.factor = 2.0,
    this.jitter = 0.5,
    math.Random? random,
  })  : assert(factor >= 1.0),
        assert(jitter >= 0.0 && jitter <= 1.0),
        _random = random ?? math.Random();

  final Duration initialDelay;
  final Duration maxDelay;
  final double factor;
  final double jitter;
  final math.Random _random;

  int _attempt = 0;

  /// Number of delays handed out since the last [reset].
  int get attempt => _attempt;

  /// Delay without jitter for a given attempt (exposed for tests).
  Duration baseDelayFor(int attempt) {
    final double ms = initialDelay.inMilliseconds * math.pow(factor, attempt).toDouble();
    final double capped = math.min(ms, maxDelay.inMilliseconds.toDouble());
    return Duration(milliseconds: capped.round());
  }

  /// Returns the next delay and advances the attempt counter.
  Duration next() {
    final double base = baseDelayFor(_attempt).inMilliseconds.toDouble();
    if (_attempt < 1000) _attempt++;
    double ms = base - base * jitter * _random.nextDouble();
    if (ms < 0) ms = 0;
    return Duration(milliseconds: ms.round());
  }

  void reset() {
    _attempt = 0;
  }

  /// Moves the attempt counter forward to at least [n] (a server overload
  /// close starts the backoff a few steps in).
  void atLeast(int n) {
    if (_attempt < n) _attempt = n;
  }
}
