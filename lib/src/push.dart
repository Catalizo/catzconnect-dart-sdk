// Device-side helpers for end-to-end encrypted push. Port of
// sdk/typescript/src/push.ts.
//
// These run in the app that RECEIVES notifications. The private key is
// generated here and must never leave the device: that is what makes the
// encryption end-to-end. Android (Kotlin) and iOS (Swift) apps use the same
// libsodium primitive, crypto_box_seal_open.

import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium_libs/sodium_libs.dart' show KeyPair, SecureKey, Sodium;

import 'core/base64.dart';
import 'core/errors.dart';
import 'core/sodium/sodium_backend.dart';

/// This device's push keypair, base64 (standard alphabet, padded).
class DeviceKeys {
  const DeviceKeys({required this.publicKey, required this.privateKey});

  /// Send this to your backend with the FCM token; pass it as `device_key`
  /// (or register it with `POST /push/register`).
  final String publicKey;

  /// Keep this on the device only — secure storage, never your server.
  final String privateKey;

  Map<String, String> toJson() => <String, String>{'publicKey': publicKey, 'privateKey': privateKey};

  factory DeviceKeys.fromJson(Map<String, dynamic> json) => DeviceKeys(
        publicKey: json['publicKey'] as String,
        privateKey: json['privateKey'] as String,
      );
}

/// A sealed notification, opened.
class PushContent {
  const PushContent({this.title, required this.body, this.data = const <String, String>{}, this.image, this.link});

  final String? title;
  final String body;
  final Map<String, String> data;
  final String? image;
  final String? link;

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (title != null) 'title': title,
        'body': body,
        'data': data,
        if (image != null) 'image': image,
        if (link != null) 'link': link,
      };

  @override
  String toString() => 'PushContent(${toJson()})';
}

/// Generate this device's keypair (`crypto_box_keypair`). Do it once, store
/// the private key in the platform's secure storage, and send the public key
/// to your backend along with the FCM token.
Future<DeviceKeys> generateDeviceKeys() async {
  final Sodium s = await CatzSodium.box();
  final KeyPair kp = s.crypto.box.keyPair();
  try {
    return DeviceKeys(publicKey: encodeBase64(kp.publicKey), privateKey: encodeBase64(kp.secretKey.extractBytes()));
  } finally {
    kp.secretKey.dispose();
  }
}

/// True when an FCM data message came from Catz Connect with sealed content.
/// Pass it the message's `data` map.
bool isSealedPush(Map<String, dynamic>? data) =>
    data != null && data['catz_v'] == '1' && data['catz_sealed'] is String;

/// Open a sealed notification (`crypto_box_seal_open`). Pass the message's
/// `data` map and this device's keys; returns the readable title, body,
/// data, image and link.
///
/// Throws if the message was sealed to a different device — for example
/// after the app was reinstalled and generated new keys without telling the
/// backend.
Future<PushContent> openPushPayload(Map<String, dynamic> data, DeviceKeys keys) async {
  if (!isSealedPush(data)) {
    throw CatzException('Not a sealed CatzConnect notification');
  }

  final Sodium s = await CatzSodium.box();
  final Uint8List publicKey = decodeBase64Lenient(keys.publicKey);
  final SecureKey secretKey = s.secureCopy(decodeBase64Lenient(keys.privateKey));
  final Uint8List opened;
  try {
    opened = s.crypto.box.sealOpen(
      cipherText: decodeBase64Lenient(data['catz_sealed'] as String),
      publicKey: publicKey,
      secretKey: secretKey,
    );
  } catch (e) {
    throw CatzException('This notification was sealed for a different device key', cause: e);
  } finally {
    secretKey.dispose();
  }

  final Object? parsed = jsonDecode(utf8.decode(opened));
  if (parsed is! Map) {
    throw CatzException('The sealed notification is not a JSON object');
  }
  final Map<String, String> d = <String, String>{};
  final Object? rawData = parsed['data'];
  if (rawData is Map) {
    rawData.forEach((Object? k, Object? v) {
      if (k != null && v != null) d[k.toString()] = v is String ? v : v.toString();
    });
  }
  String? str(Object? v) => v is String ? v : null;
  return PushContent(
    title: str(parsed['title']),
    body: str(parsed['body']) ?? '',
    data: d,
    image: str(parsed['image']),
    link: str(parsed['link']),
  );
}
