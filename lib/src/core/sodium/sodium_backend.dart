import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:sodium/sodium.dart' show Sodium, SodiumInit;

import '../errors.dart';
import 'crypto_backend.dart';
import 'server_crypto_stub.dart' if (dart.library.io) 'server_crypto_io.dart' as impl;

/// Loads libsodium (package:sodium) once and hands it to the SDK.
///
/// Both loaders are lazy: the first `send()`, `calls.*` or push helper call
/// loads what it needs. Call `CatzConnect.init()` at start-up to do it ahead
/// of time and to surface a missing native library early.
abstract final class CatzSodium {
  static Future<ServerCrypto>? _server;
  static Future<Sodium>? _box;

  /// The crypto for `send()` and `calls.*` (native platforms only).
  static Future<ServerCrypto> server() {
    final Future<ServerCrypto> f = _server ??= impl.loadServerCrypto();
    return f.catchError((Object e, StackTrace st) {
      // Let the next call try again.
      _server = null;
      if (e is UnsupportedError || e is CatzException) Error.throwWithStackTrace(e, st);
      Error.throwWithStackTrace(
          CatzException('libsodium could not be loaded (SodiumSumoInit.init): $e', cause: e), st);
    });
  }

  /// libsodium for the push helpers (every platform; on the web after
  /// `dart run sodium:update_web`).
  static Future<Sodium> box() {
    // SodiumInit.init() is synchronous on native platforms and asynchronous
    // on the web (sodium.js); Future.sync covers both and turns a throw into
    // a failed future.
    final Future<Sodium> f = _box ??= Future<Sodium>.sync(SodiumInit.init);
    return f.catchError((Object e, StackTrace st) {
      _box = null;
      Error.throwWithStackTrace(
          CatzException('libsodium could not be loaded (SodiumInit.init): $e', cause: e), st);
    });
  }

  /// Use these instances instead of loading libsodium — for tests that need
  /// a specific instance.
  @visibleForTesting
  static void debugOverride({ServerCrypto? server, Sodium? box}) {
    if (server != null) _server = Future<ServerCrypto>.value(server);
    if (box != null) _box = Future<Sodium>.value(box);
  }

  /// Forget loaded or overridden instances.
  @visibleForTesting
  static void debugReset() {
    _server = null;
    _box = null;
  }
}
