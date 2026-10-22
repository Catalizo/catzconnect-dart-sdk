// Pure-Dart SHA-256 (FIPS 180-4) and HMAC-SHA256 (RFC 2104).
//
// The libsodium binding (package:sodium) has no SHA-256 or
// HMAC-SHA256 API (`crypto.auth` is HMAC-SHA512-256), and these two are only
// used for webhook signatures and the push user_hash, which must work
// synchronously and without loading libsodium. Checked against the FIPS
// 180-4 and RFC 4231 test vectors in test/sha256_test.dart.

import 'dart:typed_data';

const List<int> _k = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, //
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const int _mask32 = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask32;

/// SHA-256 of [message]; 32 bytes.
Uint8List sha256(List<int> message) {
  final int bitLength = message.length * 8;
  // Message + 0x80 + zero padding + 8-byte big-endian length, to a multiple of 64.
  final int padded = ((message.length + 9 + 63) ~/ 64) * 64;
  final Uint8List data = Uint8List(padded);
  data.setRange(0, message.length, message);
  data[message.length] = 0x80;
  // Length in bits as a 64-bit big-endian integer. Split in two 32-bit
  // halves so this also works when compiled to JavaScript.
  final int hi = (bitLength ~/ 0x100000000) & _mask32;
  final int lo = bitLength & _mask32;
  data[padded - 8] = (hi >> 24) & 0xff;
  data[padded - 7] = (hi >> 16) & 0xff;
  data[padded - 6] = (hi >> 8) & 0xff;
  data[padded - 5] = hi & 0xff;
  data[padded - 4] = (lo >> 24) & 0xff;
  data[padded - 3] = (lo >> 16) & 0xff;
  data[padded - 2] = (lo >> 8) & 0xff;
  data[padded - 1] = lo & 0xff;

  int h0 = 0x6a09e667, h1 = 0xbb67ae85, h2 = 0x3c6ef372, h3 = 0xa54ff53a;
  int h4 = 0x510e527f, h5 = 0x9b05688c, h6 = 0x1f83d9ab, h7 = 0x5be0cd19;

  final List<int> w = List<int>.filled(64, 0);
  for (int off = 0; off < padded; off += 64) {
    for (int i = 0; i < 16; i++) {
      final int j = off + i * 4;
      w[i] = (data[j] << 24) | (data[j + 1] << 16) | (data[j + 2] << 8) | data[j + 3];
    }
    for (int i = 16; i < 64; i++) {
      final int s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final int s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask32;
    }

    int a = h0, b = h1, c = h2, d = h3, e = h4, f = h5, g = h6, h = h7;
    for (int i = 0; i < 64; i++) {
      final int s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final int ch = (e & f) ^ ((~e & _mask32) & g);
      final int t1 = (h + s1 + ch + _k[i] + w[i]) & _mask32;
      final int s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final int maj = (a & b) ^ (a & c) ^ (b & c);
      final int t2 = (s0 + maj) & _mask32;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _mask32;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask32;
    }
    h0 = (h0 + a) & _mask32;
    h1 = (h1 + b) & _mask32;
    h2 = (h2 + c) & _mask32;
    h3 = (h3 + d) & _mask32;
    h4 = (h4 + e) & _mask32;
    h5 = (h5 + f) & _mask32;
    h6 = (h6 + g) & _mask32;
    h7 = (h7 + h) & _mask32;
  }

  final Uint8List out = Uint8List(32);
  final List<int> hs = <int>[h0, h1, h2, h3, h4, h5, h6, h7];
  for (int i = 0; i < 8; i++) {
    out[i * 4] = (hs[i] >> 24) & 0xff;
    out[i * 4 + 1] = (hs[i] >> 16) & 0xff;
    out[i * 4 + 2] = (hs[i] >> 8) & 0xff;
    out[i * 4 + 3] = hs[i] & 0xff;
  }
  return out;
}

/// HMAC-SHA256 of [message] with [key]; 32 bytes.
Uint8List hmacSha256(List<int> key, List<int> message) {
  const int blockSize = 64;
  List<int> k = key;
  if (k.length > blockSize) k = sha256(k);
  final Uint8List ipad = Uint8List(blockSize);
  final Uint8List opad = Uint8List(blockSize);
  for (int i = 0; i < blockSize; i++) {
    final int b = i < k.length ? k[i] : 0;
    ipad[i] = b ^ 0x36;
    opad[i] = b ^ 0x5c;
  }
  final Uint8List inner = Uint8List(blockSize + message.length)
    ..setRange(0, blockSize, ipad)
    ..setRange(blockSize, blockSize + message.length, message);
  final Uint8List innerHash = sha256(inner);
  final Uint8List outer = Uint8List(blockSize + innerHash.length)
    ..setRange(0, blockSize, opad)
    ..setRange(blockSize, blockSize + innerHash.length, innerHash);
  return sha256(outer);
}

const String _hexDigits = '0123456789abcdef';

/// Lower-case hex of [bytes].
String toHex(List<int> bytes) {
  final StringBuffer sb = StringBuffer();
  for (final int b in bytes) {
    sb
      ..write(_hexDigits[(b >> 4) & 0xf])
      ..write(_hexDigits[b & 0xf]);
  }
  return sb.toString();
}

/// Decodes hex (either case); `null` when [hex] is not an even-length hex string.
Uint8List? fromHex(String hex) {
  if (hex.length.isOdd) return null;
  final Uint8List out = Uint8List(hex.length ~/ 2);
  for (int i = 0; i < out.length; i++) {
    final int? v = int.tryParse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}

/// Compares two byte lists without an early exit (lengths are public).
bool constantTimeEquals(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  int diff = 0;
  for (int i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
