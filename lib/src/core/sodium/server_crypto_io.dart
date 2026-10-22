// The server-API crypto on Android, iOS, macOS, Linux and Windows.
//
// Key derivation uses package:sodium's Sumo API: `crypto.scalarmult`
// (crypto_scalarmult, Sumo only) and `crypto.genericHash` (crypto_generichash).
// The AEAD is crypto_aead_chacha20poly1305_ietf, which package:sodium's
// high-level API does not wrap (`crypto.aeadChaCha20Poly1305` is the ORIGINAL
// construction with an 8-byte nonce, not the IETF one the server uses), so it
// is called through package:sodium's raw FFI bindings (`LibSodiumFFI`, exported
// by `package:sodium/sodium.ffi.dart`). Since sodium 4 those bindings resolve
// against the libsodium its build hooks bundle (native assets), the same
// library SodiumSumoInit uses — nothing to open by hand.

import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:sodium/sodium.ffi.dart' show LibSodiumFFI;
import 'package:sodium/sodium_sumo.dart' show SecureKey, SodiumSumo, SodiumSumoInit;

import '../errors.dart';
import 'crypto_backend.dart';

/// Loads the bundled libsodium and returns the server crypto.
Future<ServerCrypto> loadServerCrypto() async {
  // init() is synchronous on dart:ffi; awaiting keeps the analyzer happy with
  // the platform-neutral FutureOr signature it resolves.
  final SodiumSumo sumo = await SodiumSumoInit.init();
  return SodiumServerCrypto(sumo, const LibSodiumFFI());
}

/// [ServerCrypto] on libsodium. [sumo] must be a Sumo instance on the same
/// library as [lib] (or another copy of libsodium; the output is the same).
class SodiumServerCrypto implements ServerCrypto {
  SodiumServerCrypto(this._sumo, this._lib) {
    // sodium_init is idempotent: 0 on first call, 1 when already done.
    if (_lib.sodium_init() < 0) {
      throw CatzException('libsodium could not be initialised');
    }
  }

  final SodiumSumo _sumo;
  final LibSodiumFFI _lib;

  static final Uint8List _label = Uint8List.fromList(utf8.encode(kHandshakeLabel));

  @override
  Uint8List deriveKey(Uint8List clientPrivateKey, Uint8List serverPublicKey) {
    final SecureKey n = _sumo.secureCopy(clientPrivateKey);
    try {
      // ECDH: shared = scalarmult(client_priv, server_pub). Throws
      // SodiumException for a low-order public key, as libsodium.js does.
      final SecureKey shared = _sumo.crypto.scalarmult(n: n, p: serverPublicKey);
      try {
        // master = BLAKE2b(shared, 32)
        final Uint8List master = _sumo.crypto.genericHash(message: shared.extractBytes(), outLen: 32);
        // key = BLAKE2b(master || label, 32)
        final Uint8List km = Uint8List(master.length + _label.length)
          ..setRange(0, master.length, master)
          ..setRange(master.length, master.length + _label.length, _label);
        return _sumo.crypto.genericHash(message: km, outLen: 32);
      } finally {
        shared.dispose();
      }
    } finally {
      n.dispose();
    }
  }

  @override
  Uint8List randomNonce() => _sumo.randombytes.buf(_lib.crypto_aead_chacha20poly1305_ietf_npubbytes());

  Pointer<UnsignedChar> _alloc(int length) {
    final Pointer<Void> p = _lib.sodium_malloc(length < 1 ? 1 : length);
    if (p.address == 0) {
      throw CatzException('Encryption failed: out of memory');
    }
    return p.cast<UnsignedChar>();
  }

  Pointer<UnsignedChar> _copyIn(Uint8List bytes) {
    final Pointer<UnsignedChar> p = _alloc(bytes.length);
    if (bytes.isNotEmpty) {
      p.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
    }
    return p;
  }

  // sodium_free also wipes the memory.
  void _free(Pointer<UnsignedChar> p) => _lib.sodium_free(p.cast<Void>());

  void _check(Uint8List nonce, Uint8List key) {
    if (nonce.length != _lib.crypto_aead_chacha20poly1305_ietf_npubbytes()) {
      throw CatzException('Encryption failed: the nonce must be 12 bytes');
    }
    if (key.length != _lib.crypto_aead_chacha20poly1305_ietf_keybytes()) {
      throw CatzException('Encryption failed: the key must be 32 bytes');
    }
  }

  @override
  Uint8List seal(Uint8List message, Uint8List nonce, Uint8List key) {
    _check(nonce, key);
    final int outLength = message.length + _lib.crypto_aead_chacha20poly1305_ietf_abytes();
    final Pointer<UnsignedChar> c = _alloc(outLength);
    final Pointer<UnsignedChar> m = _copyIn(message);
    final Pointer<UnsignedChar> npub = _copyIn(nonce);
    final Pointer<UnsignedChar> k = _copyIn(key);
    try {
      final int rc = _lib.crypto_aead_chacha20poly1305_ietf_encrypt(
        c,
        nullptr, // clen_p: the length is message + abytes
        m,
        message.length,
        nullptr, // no additional data
        0,
        nullptr, // nsec: unused
        npub,
        k,
      );
      if (rc != 0) throw CatzException('Encryption failed');
      return Uint8List.fromList(c.cast<Uint8>().asTypedList(outLength));
    } finally {
      _free(c);
      _free(m);
      _free(npub);
      _free(k);
    }
  }

  @override
  Uint8List open(Uint8List cipherText, Uint8List nonce, Uint8List key) {
    _check(nonce, key);
    final int aBytes = _lib.crypto_aead_chacha20poly1305_ietf_abytes();
    if (cipherText.length < aBytes) {
      throw CatzException('Decryption failed: the ciphertext is too short');
    }
    final int mLength = cipherText.length - aBytes;
    final Pointer<UnsignedChar> m = _alloc(mLength);
    final Pointer<UnsignedChar> c = _copyIn(cipherText);
    final Pointer<UnsignedChar> npub = _copyIn(nonce);
    final Pointer<UnsignedChar> k = _copyIn(key);
    try {
      final int rc = _lib.crypto_aead_chacha20poly1305_ietf_decrypt(
        m,
        nullptr, // mlen_p
        nullptr, // nsec
        c,
        cipherText.length,
        nullptr, // no additional data
        0,
        npub,
        k,
      );
      if (rc != 0) throw CatzException('Decryption failed');
      return mLength == 0 ? Uint8List(0) : Uint8List.fromList(m.cast<Uint8>().asTypedList(mLength));
    } finally {
      _free(m);
      _free(c);
      _free(npub);
      _free(k);
    }
  }
}
