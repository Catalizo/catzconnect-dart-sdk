// App keys: challenge → Play Integrity / App Attest → app session.
//
// The flow (docs/APP_KEYS_PLAN.md, "Final wire contract"):
//   1. POST /sdk/app/challenge {platform}            → {challenge, cloud_project_number}
//   2. Android: Play Integrity classic request with nonce = challenge.
//      iOS: clientDataHash = SHA-256(UTF-8 challenge); first run generateKey +
//      attestKey, later generateAssertion with the stored key id.
//      Debug (emulator/simulator/dev builds): debug_token instead.
//   3. POST /sdk/app/session {platform, challenge, device_id, android|ios|debug_token}
//      → {session_token, expires_in, expires_at, debug, limits}
//   4. Every request carries X-Catz-App-Session: <session_token>.
//
// This file is pure Dart apart from the platform interface, so the state
// machine is tested with a fake platform and a fake API.

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kReleaseMode;

import '../core/errors.dart';
import '../core/sha256.dart';
import 'attest_platform.dart';

/// The limits the server enforces for an app key (from the session
/// response). Informational: the server is the one that counts.
class CatzAppLimits {
  const CatzAppLimits({
    this.perDevicePerHour,
    this.perRecipientPerHour,
    this.perKeyPerDay,
    this.allowedTypes = const <String>[],
    this.allowedTemplates = const <String>[],
    this.raw = const <String, dynamic>{},
  });

  final int? perDevicePerHour;
  final int? perRecipientPerHour;
  final int? perKeyPerDay;

  /// Built-in templates the key may send (v1: `Otp`).
  final List<String> allowedTypes;

  /// Organisation templates the key may send.
  final List<String> allowedTemplates;

  /// The `limits` object as received.
  final Map<String, dynamic> raw;

  static int? _int(Object? v) => v is int ? v : (v is num ? v.toInt() : (v is String ? int.tryParse(v) : null));

  static List<String> _strings(Object? v) =>
      v is List ? v.whereType<String>().toList(growable: false) : const <String>[];

  factory CatzAppLimits.fromJson(Map<String, dynamic> j) => CatzAppLimits(
        perDevicePerHour: _int(j['per_device_per_hour']),
        perRecipientPerHour: _int(j['per_recipient_per_hour']),
        perKeyPerDay: _int(j['per_key_per_day']),
        allowedTypes: _strings(j['allowed_types']),
        allowedTemplates: _strings(j['allowed_templates']),
        raw: j,
      );
}

/// An app session issued by `/sdk/app/session`.
class CatzAppSession {
  const CatzAppSession({
    required this.token,
    required this.obtainedAt,
    required this.expiresAt,
    required this.platform,
    this.debug = false,
    this.limits = const CatzAppLimits(),
  });

  /// The opaque `as1.…` token sent as `X-Catz-App-Session`.
  final String token;

  /// When this device received it (device clock).
  final DateTime obtainedAt;

  /// When it expires, on the device clock (from `expires_in` when the server
  /// sent it, so a wrong device clock does not matter).
  final DateTime expiresAt;

  /// `android` or `ios`.
  final String platform;

  /// Issued for a debug token rather than a real attestation.
  final bool debug;

  /// The key's limits.
  final CatzAppLimits limits;

  Duration get lifetime => expiresAt.difference(obtainedAt);

  /// When the SDK starts getting a new session: 20 % of the lifetime before
  /// expiry, at least 10 s and at most 5 minutes.
  DateTime get refreshAt {
    final int ms = lifetime.inMilliseconds;
    int margin = (ms * 0.2).round();
    margin = margin.clamp(10000, 300000).toInt();
    if (margin >= ms) margin = ms ~/ 2;
    return expiresAt.subtract(Duration(milliseconds: margin));
  }

  /// Parses the session response. [now] is the device clock at receipt.
  factory CatzAppSession.fromResponse(Map<String, dynamic> res, {required DateTime now, required String platform}) {
    final Map<String, dynamic> j = (res['session_token'] == null && res['data'] is Map)
        ? Map<String, dynamic>.from(res['data'] as Map)
        : res;
    final Object? token = j['session_token'];
    if (token is! String || token.isEmpty) {
      throw CatzException('Unexpected response from /sdk/app/session: no session_token');
    }
    DateTime? expires;
    final Object? inSecs = j['expires_in'];
    if (inSecs is num && inSecs > 0) {
      expires = now.add(Duration(milliseconds: (inSecs * 1000).round()));
    } else {
      final Object? at = j['expires_at'];
      if (at is String) {
        expires = DateTime.tryParse(at)?.toLocal();
      } else if (at is num) {
        // Seconds or milliseconds since the epoch.
        final int v = at.toInt();
        expires = DateTime.fromMillisecondsSinceEpoch(v < 100000000000 ? v * 1000 : v);
      }
    }
    if (expires == null || !expires.isAfter(now)) {
      expires = now.add(const Duration(minutes: 5));
    }
    final Object? limits = j['limits'];
    return CatzAppSession(
      token: token,
      obtainedAt: now,
      expiresAt: expires,
      platform: platform,
      debug: j['debug'] == true,
      limits: limits is Map ? CatzAppLimits.fromJson(Map<String, dynamic>.from(limits)) : const CatzAppLimits(),
    );
  }
}

/// A challenge from `/sdk/app/challenge`.
class CatzAppChallenge {
  const CatzAppChallenge({required this.challenge, this.expiresIn, this.cloudProjectNumber});

  /// base64url, 43 characters.
  final String challenge;
  final int? expiresIn;

  /// The key's Google Cloud project number (Android), or null.
  final String? cloudProjectNumber;

  factory CatzAppChallenge.fromResponse(Map<String, dynamic> res) {
    final Map<String, dynamic> j =
        (res['challenge'] == null && res['data'] is Map) ? Map<String, dynamic>.from(res['data'] as Map) : res;
    final Object? c = j['challenge'];
    if (c is! String || c.isEmpty) {
      throw CatzException('Unexpected response from /sdk/app/challenge: no challenge');
    }
    final Object? cpn = j['cloud_project_number'];
    final Object? exp = j['expires_in'];
    return CatzAppChallenge(
      challenge: c,
      expiresIn: exp is num ? exp.toInt() : null,
      cloudProjectNumber: cpn is String && cpn.trim().isNotEmpty ? cpn.trim() : (cpn is num ? '${cpn.toInt()}' : null),
    );
  }
}

/// The two app-key endpoints. The real one posts encrypted bodies with the
/// app key (see `HttpAppSessionApi`); tests use a fake.
///
/// Both throw a [CatzAttestationException] for `attestation_failed` /
/// `platform_not_configured`, a [CatzRateLimitException] for 429 and a
/// [CatzApiException] otherwise.
abstract interface class CatzAppSessionApi {
  Future<CatzAppChallenge> challenge(String platform);

  /// [body] is the decrypted `/sdk/app/session` request.
  Future<CatzAppSession> session(Map<String, dynamic> body, {required String platform});
}

/// What the HTTP layer needs: the current token, and a way to drop it after
/// the server said it is expired or invalid.
abstract interface class AppSessionHeaderSource {
  /// A valid session token (attesting first when needed).
  Future<String> currentToken();

  /// Forget [token] (the server refused it). The next [currentToken] gets a
  /// new session.
  void invalidate(String token);
}

/// The header that carries the app session.
const String kAppSessionHeader = 'X-Catz-App-Session';

/// The 401 codes after which the SDK gets a new session and retries once.
const Set<String> kAppSessionRetryCodes = <String>{
  'app_session_expired',
  'app_session_invalid',
  'app_session_required',
};

/// Server reasons after which the stored App Attest key is thrown away and a
/// new key is generated and attested (once).
const Set<String> kAppAttestRekeyReasons = <String>{
  'unknown_key',
  'key_exists',
  'bad_signature',
  'counter',
  // The stored key was attested under another device id (the device id was
  // reset while the key id was kept).
  'device_mismatch',
};

/// Storage keys in the plugin's preferences.
const String kDeviceIdStoreKey = 'device_id';
const String kAppAttestKeyIdStoreKeyPrefix = 'ios_key_id';

/// Gets, caches and refreshes app sessions for one app key.
///
/// - One session at a time is kept in memory; concurrent requests share one
///   attestation.
/// - A session is renewed from [CatzAppSession.refreshAt] on (shortly before
///   it expires), on the next request — there is no background timer, so an
///   idle app costs no attestations (Play Integrity has a daily quota).
///   When the renewal fails while the old session is still valid for 10 s
///   or more, the old one is used.
/// - iOS: the App Attest key id is stored per install (it is not a secret);
///   `invalid_key` from App Attest, or `unknown_key` / `key_exists` /
///   `bad_signature` / `counter` / `device_mismatch` from the server, makes
///   it generate and attest a new key once.
/// - `challenge_invalid` → a new challenge, once.
/// - A debug token is ignored in release builds (`kReleaseMode`), with a
///   printed warning: a release build always attests.
class CatzAppSessionManager implements AppSessionHeaderSource {
  CatzAppSessionManager({
    required CatzAppSessionApi api,
    required CatzAttestPlatform platform,
    required String appKey,
    String? cloudProjectNumber,
    String? debugToken,
    DateTime Function()? clock,
    Random? random,
    // Tests only: overrides kReleaseMode.
    bool? releaseMode,
  })
      // ignore: prefer_initializing_formals
      : _api = api,
        // ignore: prefer_initializing_formals
        _platform = platform,
        _keyTag = toHex(sha256(utf8.encode(appKey.trim()))).substring(0, 16),
        _cloudProjectNumber = (cloudProjectNumber == null || cloudProjectNumber.trim().isEmpty)
            ? null
            : cloudProjectNumber.trim(),
        _debugToken = effectiveDebugToken(debugToken, releaseMode: releaseMode ?? kReleaseMode),
        _clock = clock ?? DateTime.now,
        _random = random ?? Random.secure();

  /// The debug token to use: null when none was given, and null in a
  /// release build whatever was given (a debug token must never ship; the
  /// server would accept it from anyone who extracted it).
  static String? effectiveDebugToken(String? debugToken, {required bool releaseMode}) {
    final String? t = (debugToken == null || debugToken.trim().isEmpty) ? null : debugToken.trim();
    if (t != null && releaseMode) {
      debugPrint('catzconnect: debugToken is ignored in release builds — the app attests with '
          'Play Integrity / App Attest instead. Pass it in debug builds only.');
      return null;
    }
    return t;
  }

  final CatzAppSessionApi _api;
  final CatzAttestPlatform _platform;
  final String _keyTag;
  final String? _cloudProjectNumber;
  final String? _debugToken;
  final DateTime Function() _clock;
  final Random _random;

  CatzAppSession? _session;
  Future<CatzAppSession>? _inflight;
  CatzAttestDeviceInfo? _info;

  /// Whether a debug token is configured (sessions are then issued for the
  /// token instead of an attestation).
  bool get usesDebugToken => _debugToken != null;

  /// The session in memory, if any (it may be close to expiry).
  CatzAppSession? get current => _session;

  /// The App Attest key id is stored per app key, so two app keys in one app
  /// do not overwrite each other's registration.
  String get _keyIdStoreKey => '$kAppAttestKeyIdStoreKeyPrefix.$_keyTag';

  @override
  Future<String> currentToken() async => (await ensure()).token;

  @override
  void invalidate(String token) {
    if (_session?.token == token) _session = null;
  }

  /// Forget the session in memory (the next request attests again).
  void clear() => _session = null;

  /// A valid session: the cached one, or a new one. [force] skips the cache.
  Future<CatzAppSession> ensure({bool force = false}) {
    final CatzAppSession? s = _session;
    final DateTime now = _clock();
    if (!force && s != null && now.isBefore(s.refreshAt)) {
      return Future<CatzAppSession>.value(s);
    }
    final Future<CatzAppSession>? running = _inflight;
    if (running != null) return running;

    final Future<CatzAppSession> f = _obtain().then((CatzAppSession fresh) {
      _session = fresh;
      return fresh;
    }, onError: (Object e, StackTrace st) {
      // Renewal failed: keep using the old session while it is still valid.
      final CatzAppSession? old = _session;
      if (!force && old != null && _clock().isBefore(old.expiresAt.subtract(const Duration(seconds: 10)))) {
        return old;
      }
      Error.throwWithStackTrace(e, st);
    });
    _inflight = f;
    f.then((_) => _inflight = null, onError: (Object _) => _inflight = null);
    return f;
  }

  /// Forget this install's stored App Attest key and device id (for a
  /// "reset" button in a debug menu). Sessions are dropped too.
  Future<void> resetDevice() async {
    _session = null;
    await _platform.remove(_keyIdStoreKey);
    await _platform.remove(kDeviceIdStoreKey);
  }

  Future<CatzAttestDeviceInfo> _deviceInfo() async => _info ??= await _platform.info();

  /// The install's random id (8–128 chars of [A-Za-z0-9_-]); created once.
  Future<String> deviceId() async {
    final String? stored = await _platform.read(kDeviceIdStoreKey);
    if (stored != null && RegExp(r'^[A-Za-z0-9_-]{8,128}$').hasMatch(stored)) return stored;
    final Uint8List bytes = Uint8List.fromList(List<int>.generate(16, (_) => _random.nextInt(256)));
    final String id = base64Url.encode(bytes).replaceAll('=', '');
    await _platform.write(kDeviceIdStoreKey, id);
    return id;
  }

  Future<CatzAppSession> _obtain() async {
    final CatzAttestDeviceInfo info = await _deviceInfo();
    final String platform = info.platform;
    if (platform != 'android' && platform != 'ios') {
      throw CatzAttestationException('unsupported_platform',
          'App keys work on Android and iOS only (this is "$platform"). Use a server key from your backend.',
          platform: platform);
    }
    final String? debugToken = _debugToken;
    if (debugToken == null && platform == 'ios') {
      if (info.emulator) {
        throw CatzAttestationException(
          'simulator_requires_debug_token',
          'App Attest does not work in the iOS Simulator. Create a debug token on the app key '
              '(API keys → your app key → Debug tokens) and pass it as CatzConnect.app(debugToken: …) '
              'in debug builds only.',
          platform: platform,
        );
      }
      if (!info.appAttestSupported) {
        throw CatzAttestationException(
          'app_attest_unsupported',
          'App Attest is not supported on this device (iOS ${info.osVersion ?? '?'}; it needs iOS 14 or '
              'later and is not available in some app extensions).',
          platform: platform,
        );
      }
    }
    final String installId = await deviceId();
    try {
      return await _attempt(platform, installId, debugToken);
    } on CatzAttestationException catch (e) {
      if (debugToken == null && platform == 'android' && info.emulator) {
        throw CatzAttestationException(
          'emulator_requires_debug_token',
          'Play Integrity cannot vouch for an Android emulator (${e.reason}: ${e.message}). Create a debug '
              'token on the app key and pass it as CatzConnect.app(debugToken: …) in debug builds only.',
          platform: platform,
          source: e.source,
          nativeCode: e.nativeCode,
          status: e.status,
          body: e.body,
          cause: e,
        );
      }
      rethrow;
    }
  }

  Future<CatzAppSession> _attempt(String platform, String deviceId, String? debugToken) async {
    bool newChallengeTried = false;
    bool rekeyed = false;
    while (true) {
      final CatzAppChallenge ch = await _api.challenge(platform);
      final Map<String, dynamic> body = <String, dynamic>{
        'platform': platform,
        'challenge': ch.challenge,
        'device_id': deviceId,
      };
      String? newKeyId; // set when this attempt attests a new App Attest key

      if (debugToken != null) {
        body['debug_token'] = debugToken;
      } else if (platform == 'android') {
        final String token = await _platform.requestIntegrityToken(
          nonce: ch.challenge,
          cloudProjectNumber: _cloudProjectNumber ?? ch.cloudProjectNumber,
        );
        body['android'] = <String, dynamic>{'integrity_token': token};
      } else {
        final Uint8List clientDataHash = sha256(utf8.encode(ch.challenge));
        String? keyId = await _platform.read(_keyIdStoreKey);
        if (keyId != null && keyId.isEmpty) keyId = null;
        Uint8List? assertion;
        if (keyId != null) {
          try {
            assertion = await _platform.appAttestGenerateAssertion(keyId, clientDataHash);
          } on CatzAttestationException catch (e) {
            // The key is gone (app reinstalled, restored to a new device, …).
            if (e.reason != 'app_attest_invalid_key' || rekeyed) rethrow;
            rekeyed = true;
            await _platform.remove(_keyIdStoreKey);
            keyId = null;
          }
        }
        if (keyId == null || assertion == null) {
          final String fresh = await _platform.appAttestGenerateKey();
          final Uint8List attestation = await _platform.appAttestAttestKey(fresh, clientDataHash);
          newKeyId = fresh;
          body['ios'] = <String, dynamic>{'key_id': fresh, 'attestation': base64.encode(attestation)};
        } else {
          body['ios'] = <String, dynamic>{'key_id': keyId, 'assertion': base64.encode(assertion)};
        }
      }

      try {
        final CatzAppSession s = await _api.session(body, platform: platform);
        // Keep the App Attest key only once the server has registered it.
        if (newKeyId != null) await _platform.write(_keyIdStoreKey, newKeyId);
        return s;
      } on CatzAttestationException catch (e) {
        if (e.reason == 'challenge_invalid' && !newChallengeTried) {
          newChallengeTried = true;
          continue;
        }
        if (platform == 'ios' && debugToken == null && !rekeyed && newKeyId == null &&
            kAppAttestRekeyReasons.contains(e.reason)) {
          rekeyed = true;
          await _platform.remove(_keyIdStoreKey);
          continue;
        }
        rethrow;
      }
    }
  }
}
