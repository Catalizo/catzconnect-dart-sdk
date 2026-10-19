import 'dart:convert';
import 'dart:typed_data';

import 'errors.dart';

final RegExp _whitespace = RegExp(r'\s+');

/// Decodes base64 leniently, like the Go and Rust SDKs: surrounding (and
/// embedded) whitespace, URL-safe characters and missing padding are all
/// accepted. Keys reach the SDK from .env files, secret managers and
/// copy-paste, and each adds its own damage.
Uint8List decodeBase64Lenient(String s) {
  String n = s.replaceAll(_whitespace, '').replaceAll('-', '+').replaceAll('_', '/');
  n = n.replaceAll(RegExp(r'=+$'), '');
  final int rem = n.length % 4;
  if (rem == 1) {
    throw CatzException('Base64 decode error: invalid length');
  }
  if (rem != 0) n = n + '=' * (4 - rem);
  try {
    return base64.decode(n);
  } on FormatException catch (e) {
    throw CatzException('Base64 decode error: ${e.message}', cause: e);
  }
}

/// Standard base64 with padding (what the API and the other SDKs send).
String encodeBase64(List<int> bytes) => base64.encode(bytes);

/// Decodes a key and insists on exactly 32 bytes, so a truncated or wrong key
/// fails with a message that says so.
Uint8List decodeKey32(String b64) {
  final Uint8List b = decodeBase64Lenient(b64);
  if (b.length != 32) {
    throw CatzException('Invalid key length — expected 32 bytes, got ${b.length}');
  }
  return b;
}
