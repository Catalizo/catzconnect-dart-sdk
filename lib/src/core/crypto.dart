// Request encryption and response decryption. Port of
// sdk/typescript/src/core/crypto.ts:
// X25519 → BLAKE2b-256 → BLAKE2b-256(master ‖ "CONNECT-@-2026-HS-@-CATZ"),
// then ChaCha20-Poly1305 (IETF) over JSON.stringify({...payload, ts}).

import 'dart:convert';
import 'dart:typed_data';

import 'base64.dart';
import 'env.dart';
import 'errors.dart';
import 'sodium/crypto_backend.dart';
import 'sodium/sodium_backend.dart';

/// The request body: `{ "nonce": base64, "ciphertext": base64 }`.
class EncryptedBody {
  const EncryptedBody({required this.nonce, required this.ciphertext});

  final String nonce;
  final String ciphertext;

  Map<String, String> toJson() => <String, String>{'nonce': nonce, 'ciphertext': ciphertext};
}

Uint8List _deriveKey(ServerCrypto s, ResolvedKeys keys) {
  final Uint8List priv = decodeKey32(keys.privateKey);
  final Uint8List pub = decodeKey32(keys.serverPublicKey);
  try {
    return s.deriveKey(priv, pub);
  } on CatzException {
    rethrow;
  } catch (e) {
    throw CatzException('Encryption failed', cause: e);
  }
}

/// Adds `ts` (milliseconds since the epoch) to [payload], serialises it as
/// JSON and seals it for the server.
///
/// [nonce] and [timestampMs] exist for the fixed test vectors; leave them
/// out in real use.
Future<EncryptedBody> encryptPayload(
  Map<String, dynamic> payload,
  ResolvedKeys keys, {
  Uint8List? nonce,
  int? timestampMs,
}) async {
  final ServerCrypto s = await CatzSodium.server();
  final Uint8List key = _deriveKey(s, keys);

  final Map<String, dynamic> fp = <String, dynamic>{
    ...payload,
    'ts': timestampMs ?? DateTime.now().millisecondsSinceEpoch,
  };

  final Uint8List message = Uint8List.fromList(utf8.encode(jsonEncode(fp)));
  final Uint8List n = nonce ?? s.randomNonce(); // 12 bytes
  final Uint8List ciphertext;
  try {
    ciphertext = s.seal(message, n, key);
  } on CatzException {
    rethrow;
  } catch (e) {
    throw CatzException('Encryption failed', cause: e);
  }
  return EncryptedBody(nonce: encodeBase64(n), ciphertext: encodeBase64(ciphertext));
}

bool _isSealed(Object? v) =>
    v is Map && v.length == 2 && v['nonce'] is String && v['ciphertext'] is String;

/// Opens a response that carries an encrypted `{nonce, ciphertext}` envelope
/// (at the top level or as `data`) with the same key as the request, and
/// merges the decrypted object in. A plain JSON response is returned as is —
/// which is what `/sdk/*` sends today.
Future<Map<String, dynamic>> openResponse(Map<String, dynamic> res, ResolvedKeys keys) async {
  final bool sealedTop = _isSealed(res);
  final Object? sealed = sealedTop ? res : (_isSealed(res['data']) ? res['data'] : null);
  if (sealed is! Map) return res;

  final ServerCrypto s = await CatzSodium.server();
  Uint8List plain;
  try {
    plain = s.open(
      decodeBase64Lenient(sealed['ciphertext'] as String),
      decodeBase64Lenient(sealed['nonce'] as String),
      _deriveKey(s, keys),
    );
  } catch (e) {
    throw CatzException('The response is encrypted with a key this SDK cannot open', cause: e);
  }
  final Object? opened = jsonDecode(utf8.decode(plain));
  if (sealedTop) {
    return opened is Map ? Map<String, dynamic>.from(opened) : <String, dynamic>{'data': opened};
  }
  final Map<String, dynamic> rest = Map<String, dynamic>.from(res)..remove('data');
  if (opened is Map) {
    return <String, dynamic>{...rest, ...Map<String, dynamic>.from(opened), 'data': opened};
  }
  return <String, dynamic>{...rest, 'data': opened};
}
