// The native side of app keys: Play Integrity (Android) and App Attest
// (iOS), reached through the `catzconnect/attest` method channel that the
// plugin's android/ (Kotlin) and ios/ (Swift) code registers.

import 'dart:async';

import 'package:flutter/services.dart';

import '../core/errors.dart';

/// What the plugin reports about the device.
class CatzAttestDeviceInfo {
  const CatzAttestDeviceInfo({
    required this.platform,
    this.emulator = false,
    this.appAttestSupported = false,
    this.osVersion,
  });

  /// `android` or `ios`.
  final String platform;

  /// iOS: running in the Simulator (exact, compile-time). Android: the build
  /// properties look like an emulator (a heuristic, used only to explain a
  /// failure — it never blocks a real device).
  final bool emulator;

  /// iOS: `DCAppAttestService.shared.isSupported` (false in the Simulator,
  /// before iOS 14 and in some app extensions). Always false on Android.
  final bool appAttestSupported;

  /// The OS version string, for error messages.
  final String? osVersion;

  factory CatzAttestDeviceInfo.fromMap(Map<Object?, Object?> m) => CatzAttestDeviceInfo(
        platform: (m['platform'] as String?) ?? '',
        emulator: m['emulator'] == true,
        appAttestSupported: m['appAttestSupported'] == true,
        osVersion: m['osVersion'] as String?,
      );
}

/// The native calls app keys need. [MethodChannelAttestPlatform] is the real
/// one; tests pass a fake to `CatzConnect.app(attestPlatform: …)`.
///
/// Every method throws a [CatzAttestationException] on failure.
abstract interface class CatzAttestPlatform {
  /// Platform, simulator/emulator, App Attest support.
  Future<CatzAttestDeviceInfo> info();

  /// Small non-secret values kept by the plugin (SharedPreferences on
  /// Android, UserDefaults on iOS): the install's device id and the App
  /// Attest key id.
  Future<String?> read(String key);

  /// Stores [value] under [key] (see [read]).
  Future<void> write(String key, String value);

  /// Removes [key] (see [read]).
  Future<void> remove(String key);

  /// Android: a classic Play Integrity request,
  /// `IntegrityManagerFactory.create(context).requestIntegrityToken(
  /// IntegrityTokenRequest.builder().setNonce(nonce)
  /// .setCloudProjectNumber(n).build())`. Returns the token.
  Future<String> requestIntegrityToken({required String nonce, String? cloudProjectNumber});

  /// iOS: `DCAppAttestService.shared.generateKey` → the key id.
  Future<String> appAttestGenerateKey();

  /// iOS: `DCAppAttestService.shared.attestKey(keyId, clientDataHash:)` →
  /// the attestation object (CBOR).
  Future<Uint8List> appAttestAttestKey(String keyId, Uint8List clientDataHash);

  /// iOS: `DCAppAttestService.shared.generateAssertion(keyId,
  /// clientDataHash:)` → the assertion object (CBOR).
  Future<Uint8List> appAttestGenerateAssertion(String keyId, Uint8List clientDataHash);
}

/// The method channel the plugin registers.
const String kCatzAttestChannel = 'catzconnect/attest';

/// [CatzAttestPlatform] over the `catzconnect/attest` method channel.
///
/// Native errors arrive as a `PlatformException` whose `code` is the reason
/// (with `details: {errorCode}`) and are turned into
/// [CatzAttestationException]s with that reason. A missing plugin (web, desktop, or a test without the
/// plugin) becomes reason `unsupported_platform`.
class MethodChannelAttestPlatform implements CatzAttestPlatform {
  MethodChannelAttestPlatform({MethodChannel? channel, this.timeout = const Duration(seconds: 60)})
      : _channel = channel ?? const MethodChannel(kCatzAttestChannel);

  final MethodChannel _channel;

  /// Longest wait for one native call (Play Integrity and App Attest talk to
  /// Google's / Apple's servers). Exceeding it throws reason `timeout`.
  final Duration timeout;

  String? _platform;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args).timeout(timeout);
    } on TimeoutException catch (e) {
      throw CatzAttestationException('timeout', 'The device attestation ($method) did not finish within '
          '${timeout.inSeconds} s.', platform: _platform, cause: e);
    } on MissingPluginException catch (e) {
      throw CatzAttestationException(
        'unsupported_platform',
        'App keys need the catzconnect plugin on Android or iOS (method channel "$kCatzAttestChannel" '
            'is not registered here). Use a server key from your backend on other platforms.',
        platform: _platform,
        cause: e,
      );
    } on PlatformException catch (e) {
      throw attestationErrorFromPlatform(e, platform: _platform);
    }
  }

  @override
  Future<CatzAttestDeviceInfo> info() async {
    final Map<Object?, Object?>? m = await _call<Map<Object?, Object?>>('info');
    final CatzAttestDeviceInfo i = CatzAttestDeviceInfo.fromMap(m ?? const <Object?, Object?>{});
    _platform = i.platform;
    return i;
  }

  @override
  Future<String?> read(String key) => _call<String>('read', <String, Object?>{'key': key});

  @override
  Future<void> write(String key, String value) =>
      _call<void>('write', <String, Object?>{'key': key, 'value': value});

  @override
  Future<void> remove(String key) => _call<void>('remove', <String, Object?>{'key': key});

  @override
  Future<String> requestIntegrityToken({required String nonce, String? cloudProjectNumber}) async {
    final String? token = await _call<String>('requestIntegrityToken', <String, Object?>{
      'nonce': nonce,
      'cloudProjectNumber': ?cloudProjectNumber,
    });
    if (token == null || token.isEmpty) {
      throw CatzAttestationException('integrity_empty_token', 'Play Integrity returned no token.',
          platform: 'android');
    }
    return token;
  }

  @override
  Future<String> appAttestGenerateKey() async {
    final String? keyId = await _call<String>('generateKey');
    if (keyId == null || keyId.isEmpty) {
      throw CatzAttestationException('app_attest_failed', 'App Attest returned no key id.', platform: 'ios');
    }
    return keyId;
  }

  @override
  Future<Uint8List> appAttestAttestKey(String keyId, Uint8List clientDataHash) async {
    final Uint8List? out = await _call<Uint8List>(
        'attestKey', <String, Object?>{'keyId': keyId, 'clientDataHash': clientDataHash});
    if (out == null || out.isEmpty) {
      throw CatzAttestationException('app_attest_failed', 'App Attest returned no attestation.', platform: 'ios');
    }
    return out;
  }

  @override
  Future<Uint8List> appAttestGenerateAssertion(String keyId, Uint8List clientDataHash) async {
    final Uint8List? out = await _call<Uint8List>(
        'generateAssertion', <String, Object?>{'keyId': keyId, 'clientDataHash': clientDataHash});
    if (out == null || out.isEmpty) {
      throw CatzAttestationException('app_attest_failed', 'App Attest returned no assertion.', platform: 'ios');
    }
    return out;
  }
}

/// Turns the plugin's `PlatformException` into a [CatzAttestationException].
/// The native code puts the reason in `code` and the native error number in
/// `details['errorCode']`.
CatzAttestationException attestationErrorFromPlatform(PlatformException e, {String? platform}) {
  final Object? details = e.details;
  int? nativeCode;
  if (details is Map) {
    final Object? n = details['errorCode'];
    if (n is int) nativeCode = n;
  }
  final String reason = e.code.isEmpty ? 'attestation_error' : e.code;
  final String message = (e.message == null || e.message!.isEmpty) ? 'Device attestation failed ($reason)' : e.message!;
  return CatzAttestationException(reason, message, platform: platform, nativeCode: nativeCode, cause: e);
}
