import 'crypto_backend.dart';

/// Flutter web (no dart:io / dart:ffi): the server API is not available.
Future<ServerCrypto> loadServerCrypto() => Future<ServerCrypto>.error(UnsupportedError(
      'CatzConnect.send() and calls.* are not available on Flutter web: they need dart:io and the native '
      'libsodium. Call them from your backend (recommended anyway: an API key in a web app is public). '
      'The push helpers and the call client work on the web.',
    ));
