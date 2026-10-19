import '../types.dart';
import '../version.dart';
import 'env_stub.dart' if (dart.library.io) 'env_io.dart' as platform;
import 'errors.dart';

// `--dart-define=CATZCONNECT_API_KEY=…` etc. Compile-time constants, so they
// have to be spelled out.
const String _defineApiKey = String.fromEnvironment('CATZCONNECT_API_KEY');
const String _definePrivateKey = String.fromEnvironment('CATZCONNECT_PRIVATE_KEY');
const String _defineServerPublicKey = String.fromEnvironment('CATZCONNECT_SERVER_PUBLIC_KEY');
const String _defineBaseUrl = String.fromEnvironment('CATZCONNECT_BASE_URL');

/// Reads a `CATZCONNECT_*` value: a `--dart-define` first, then the process
/// environment (desktop and `flutter test`; mobile apps have none).
String? readEnv(String name) {
  String define = '';
  switch (name) {
    case 'CATZCONNECT_API_KEY':
      define = _defineApiKey;
    case 'CATZCONNECT_PRIVATE_KEY':
      define = _definePrivateKey;
    case 'CATZCONNECT_SERVER_PUBLIC_KEY':
      define = _defineServerPublicKey;
    case 'CATZCONNECT_BASE_URL':
      define = _defineBaseUrl;
  }
  if (define.isNotEmpty) return define;
  final String? v = platform.environmentValue(name);
  return (v == null || v.isEmpty) ? null : v;
}

/// The two keys that encrypt a request.
class ResolvedKeys {
  const ResolvedKeys({required this.privateKey, required this.serverPublicKey});

  final String privateKey;
  final String serverPublicKey;
}

/// The keys from [env], or from `CATZCONNECT_PRIVATE_KEY` and
/// `CATZCONNECT_SERVER_PUBLIC_KEY`.
ResolvedKeys resolveKeys(EnvValues? env) {
  if (env != null) {
    return ResolvedKeys(privateKey: env.privateKey, serverPublicKey: env.serverPublicKey);
  }
  final String? priv = readEnv('CATZCONNECT_PRIVATE_KEY');
  final String? pub = readEnv('CATZCONNECT_SERVER_PUBLIC_KEY');
  if (priv == null || pub == null) {
    throw CatzException('Missing keys, Make sure keys exists at Environment');
  }
  return ResolvedKeys(privateKey: priv, serverPublicKey: pub);
}

/// The API key from [env] or `CATZCONNECT_API_KEY`, trimmed (a key from a
/// .env file may end in a newline).
String resolveApiKey(EnvValues? env) {
  final String raw = (env != null ? env.apiKey : readEnv('CATZCONNECT_API_KEY')) ?? '';
  final String key = raw.trim();
  if (key.isEmpty) {
    throw CatzException('Missing API key in environment');
  }
  return key;
}

final RegExp _trailingSlashes = RegExp(r'/+$');

/// [configured], else `CATZCONNECT_BASE_URL`, else
/// `https://api.catzconnect.com`; trimmed and without a trailing slash (which
/// would produce `//sdk/send`).
String resolveBaseUrl(String? configured) {
  final String raw = (configured ?? readEnv('CATZCONNECT_BASE_URL') ?? kDefaultBaseUrl).trim();
  final String url = raw.replaceAll(_trailingSlashes, '');
  return url.isEmpty ? kDefaultBaseUrl : url;
}
