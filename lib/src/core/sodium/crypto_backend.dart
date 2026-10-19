import 'dart:typed_data';

/// Mixed into key derivation; must match the server and every other SDK.
const String kHandshakeLabel = 'CONNECT-@-2026-HS-@-CATZ';

/// The libsodium operations the server API (send and calls) needs:
/// X25519 → BLAKE2b-256 → BLAKE2b-256(master ‖ label) key derivation and
/// ChaCha20-Poly1305 (IETF, 12-byte nonce) without additional data.
abstract interface class ServerCrypto {
  /// `crypto_generichash(32, crypto_generichash(32, crypto_scalarmult(priv, pub)) ‖ label)`.
  Uint8List deriveKey(Uint8List clientPrivateKey, Uint8List serverPublicKey);

  /// 12 random bytes (`randombytes_buf`).
  Uint8List randomNonce();

  /// `crypto_aead_chacha20poly1305_ietf_encrypt` (no additional data).
  Uint8List seal(Uint8List message, Uint8List nonce, Uint8List key);

  /// `crypto_aead_chacha20poly1305_ietf_decrypt`. Throws when the tag does not
  /// verify.
  Uint8List open(Uint8List cipherText, Uint8List nonce, Uint8List key);
}
