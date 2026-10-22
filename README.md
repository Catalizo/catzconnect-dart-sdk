# catzconnect (Flutter)

The [Catz Connect](https://catzconnect.com) SDK for Flutter, version 2.0.0, in
step with the TypeScript, Go, PHP and Rust SDKs:

- **`send()`** for Email, WhatsApp, Push, SMS and Voice (phone calls), with
  the same validation, payloads, encryption and errors as the other SDKs.
- **Calls server API**: `calls.create`, `calls.token`, `calls.get`,
  `calls.end`.
- **Call client** (`CatzCallClient`): peer-to-peer WebRTC voice and video
  with relay fallback, ICE restarts and signaling reconnects; provider
  hand-off; ringing through push.
- **Push helpers**: `generateDeviceKeys`, `isSealedPush`, `openPushPayload`
  for end-to-end encrypted notifications; `computeUserHash` and
  `verifyWebhookSignature` for your server.
- **App keys** (`CatzConnect.app`): call the API straight from a mobile app
  without the key being usable elsewhere — sessions are issued only after a
  Google Play Integrity (Android) or Apple App Attest (iOS) check. See
  [App keys](#app-keys-mobile-apps).
- SMS and Voice helpers: `analyseSms`, `normaliseE164`, `isValidSmsSender`,
  `isValidDltId`, `validateVoiceText`, `isValidVoiceLanguage`, …

This package replaces `catzconnect_calls` (1.0.0). The call client API is
unchanged; only the import changes (see [Migrating](#migrating-from-catzconnect_calls)).

---

## ⚠️ SECURITY WARNING: keys inside an app are public

**Anything you ship in an app — an API key, your private key, a
`--dart-define` value, an obfuscated string — can be extracted by anyone who
downloads and unpacks the app.** Obfuscation and code shrinking slow this
down; they do not stop it. Whoever extracts the key can send messages and
create calls on your account, up to everything that key allows.

The recommended pattern:

| Where | What |
| --- | --- |
| **Your backend** | `send()` for every channel, `calls.create` / `calls.token` / `calls.get` / `calls.end`, `computeUserHash`, `verifyWebhookSignature`. The API key, `CATZCONNECT_PRIVATE_KEY` and the push identity secret (`pis_…`) live only here. |
| **The app** | `CatzCallClient` with a short-lived user token your backend minted (`ct1.…`, never contains the API key), `CatzCalls.incomingFromPush`, and the push helpers `generateDeviceKeys` / `isSealedPush` / `openPushPayload`. |

The app asks *your* backend (with your own user authentication) to send the
OTP or create the call; your backend calls Catz Connect.

**No backend? Use an [app key](#app-keys-mobile-apps)** instead of a server
key: it only works with an app session that the server issues after a Play
Integrity / App Attest check, so a copy taken out of the app is useless.

If you decide to embed a *server* key in an app anyway (an internal tool, a
kiosk, a prototype):

1. **Create a dedicated key for the app** in the panel (Developers → API
   keys) and **restrict it to exactly what the app needs**: only the
   channels, the identities (mailboxes, numbers, Firebase projects), the
   templates, the SMS gateways and the call/voice providers it uses. Never
   embed your main server key.
2. Prefer templates over `Custom` bodies, so a leaked key cannot send
   arbitrary text.
3. Watch usage and **rotate the key immediately if it leaks** (revoke it in
   the panel and ship a new build). Revoking a key also invalidates every
   call token it minted.
4. Never put the push identity secret (`pis_…`) or a webhook signing secret
   (`whsec_…`) in an app.

## App keys (mobile apps)

An **app key** is an API key made for apps that call Catz Connect directly —
typically to send a sign-in code — without a backend of your own. It only
works together with a short-lived **app session**, which the server issues
after the device proves it is running *your genuine app*:

- **Android**: a [Google Play Integrity](https://developer.android.com/google/play/integrity)
  verdict (classic request). The server decodes it with your Google service
  account and checks the package name, your signing certificate, that Google
  Play recognises the app (`PLAY_RECOGNIZED`) and that the device passes
  `MEETS_DEVICE_INTEGRITY` (or `MEETS_STRONG_INTEGRITY` when the key asks for it).
- **iOS**: [Apple App Attest](https://developer.apple.com/documentation/devicecheck/establishing-your-app-s-integrity)
  (`DCAppAttestService`). The first run attests a hardware-backed key (team
  ID + bundle ID, certificate chain to Apple's root); later sessions use an
  assertion signed with that key.

So an app key copied out of the app is useless on its own: every request also
needs `X-Catz-App-Session`, and only the genuine app on a real device can get
one. On top of that the server enforces the key's limits (per device per
hour, per recipient per hour, per key per day, allowed templates — by
default only the built-in `Otp`; never `Custom` bodies), because attestation
does not stop abuse *through* the genuine app.

### How it works

```
app ──POST /sdk/app/challenge {platform}──────────────▶ Catz Connect   (Bearer app key, encrypted)
    ◀── challenge (single use, 5 min), cloud_project_number
app ── Android: Play Integrity token, nonce = challenge
       iOS: generateKey + attestKey (first run) or generateAssertion,
            clientDataHash = SHA-256(challenge)
app ──POST /sdk/app/session {challenge, device_id, token | attestation | assertion}──▶
    ◀── session_token (as1.…), expires_in (default 1 h), limits
app ──POST /sdk/send   X-Catz-App-Session: as1.…──────▶
```

The SDK does all of this for you:

```dart
final CatzConnect catz = CatzConnect.app(
  appKey: const String.fromEnvironment('CATZ_APP_KEY'),
  privateKey: const String.fromEnvironment('CATZ_APP_PRIVATE_KEY'),
  serverPublicKey: const String.fromEnvironment('CATZ_SERVER_PUBLIC_KEY'),
  // Android, optional: the Cloud project linked in Play Console. When null,
  // the number saved on the app key is used.
  playCloudProjectNumber: null,
  // Emulators, the iOS Simulator and builds not installed from Google Play.
  // Never in release builds.
  debugToken: kReleaseMode ? null : const String.fromEnvironment('CATZ_DEBUG_TOKEN'),
);

await catz.send(SendInput(
  channel: Channel.sms,
  type: MessageType.verification,
  template: Template.otp,
  payload: SendPayload(to: phone, otp: code),
));
```

- The session is requested on the first request (or call
  `await catz.appSession!.ensure()` at start-up to attest ahead of time),
  cached in memory, and renewed on the next request once it is within 20 % of
  its lifetime of expiring (at most 5 minutes before). There is no background
  timer, so an idle app spends no attestations. If a renewal fails while the
  old session is still valid, the old one is used.
- Concurrent requests share one attestation.
- A request refused with `app_session_expired`, `app_session_invalid` or
  `app_session_required` (the key's settings changed, "sign out all
  devices", key rolled) gets a new session and is sent once more.
- `device_id`: a random id created once per install (22 characters,
  base64url) and stored by the plugin (SharedPreferences on Android,
  UserDefaults on iOS). It is not a hardware identifier and is not secret;
  the per-device limit counts it.
- iOS: the App Attest key id is stored the same way (it is not secret either;
  the private key never leaves the Secure Enclave). If App Attest reports
  `invalidKey` (the app was reinstalled or restored onto another device) or
  the server answers `unknown_key`, `key_exists`, `bad_signature`,
  `counter` or `device_mismatch`, the SDK discards it, generates a new key and attests again —
  once.
- `challenge_invalid` (used or expired challenge) → a new challenge, once.
- `catz.appSession!.current` has the session's `expiresAt`, `debug` flag and
  `limits`; `clear()` drops it, `resetDevice()` also forgets the device id
  and the App Attest key.

`calls.*` is not available with app keys (`not_allowed_for_app_keys`): mint
call tokens on your backend with a server key.

### App key errors

```dart
try {
  await catz.send(input);
} on CatzAttestationException catch (e) {
  // e.reason, e.source (device | server), e.retryable, e.platform, e.nativeCode
} on CatzRateLimitException catch (e) {
  // 429: e.retryAfter, e.limit ('device' | 'recipient' | 'key')
} on CatzApiException catch (e) {
  // template_not_allowed, custom_body_not_allowed, not_an_app_key, …
}
```

| `reason` | Source | Meaning / what to do |
| --- | --- | --- |
| `not_play_recognized` | server | The build was not installed from Google Play (sideloaded, `flutter run`). Use an internal testing track, or a debug token while developing. |
| `device_integrity` | server | The device fails Play's device integrity (rooted, emulator, unlocked bootloader). |
| `wrong_package` / `wrong_certificate` | server | The package name or signing certificate does not match the key. Add the SHA-256 of the **app signing key** from Play Console. |
| `nonce_mismatch`, `expired`, `challenge_invalid` | server | The verdict does not belong to this challenge or is too old; retrying usually works. |
| `play_api_error` | server | Google's decode call failed (service account, API not enabled, quota). Retry later; check the key's service account. |
| `unknown_key`, `key_exists`, `bad_signature`, `counter`, `device_mismatch` | server | App Attest key problems; the SDK re-attests once by itself. |
| `wrong_environment` | server | The App Attest environment (development / production) does not match the key's iOS environment. |
| `bad_format`, `not_configured`, `platform_not_configured` | server | Malformed token, or the key has no settings for this platform. |
| `debug_not_allowed`, `bad_debug_token` | server | Debug tokens are off on the key, or the token was revoked / mistyped. |
| `simulator_requires_debug_token` | device | App Attest does not work in the iOS Simulator; pass `debugToken`. |
| `emulator_requires_debug_token` | device | An Android emulator failed attestation; pass `debugToken`. |
| `app_attest_unsupported` | device | iOS before 14, or an app extension. |
| `integrity_<code>` | device | A Play Integrity `IntegrityErrorCode`, e.g. `integrity_network_error`, `integrity_play_store_not_found`, `integrity_play_services_version_outdated`, `integrity_cloud_project_number_is_invalid`. |
| `app_attest_<code>` | device | A `DCError`: `app_attest_invalid_key`, `app_attest_server_unavailable`, `app_attest_feature_unsupported`, `app_attest_invalid_input`, `app_attest_unknown_system_failure`. |
| `unsupported_platform`, `timeout` | device | Not Android/iOS (or the plugin is not registered), or the native call took longer than 60 s. |

### Android setup

1. **Play Console** → your app → *Test and release* → *App integrity* →
   *Play Integrity API*: **link a Google Cloud project** (create one if
   needed). Note its **project number** (Cloud console → project
   dashboard); enable the *Google Play Integrity API* in that project.
2. In the same Cloud project, **create a service account** (IAM & Admin →
   Service accounts → Create) and a **JSON key** for it (Keys → Add key →
   JSON). No extra role is needed: the account only calls
   `decodeIntegrityToken` for apps linked to its project.
3. **Signing certificate**: Play Console → *App integrity* → *App signing* →
   copy the **SHA-256 certificate fingerprint of the app signing key** (and
   of the upload key if you also test builds that are not re-signed by Play).
4. In the panel: **Developers → API keys → Create key → App key** → *Android*: package
   name, the SHA-256 fingerprint(s), the project number, and upload the
   service-account JSON (stored encrypted, never shown again).
5. Nothing to add to your app: the plugin brings
   `com.google.android.play:integrity:1.4.0`. `minSdkVersion` 23 as before.

Play Integrity verdicts only pass for builds **installed from Google Play**
(any track, including internal testing). Classic requests count against the
Play Integrity daily quota of your app (10,000 by default; Google raises it
on request), which is why the SDK reuses sessions instead of attesting per
request.

### iOS setup

1. In Xcode → *Runner* target → *Signing & Capabilities* → **+ Capability →
   App Attest**. This adds `com.apple.developer.devicecheck.appattest-environment`
   to `Runner.entitlements`:

   ```xml
   <key>com.apple.developer.devicecheck.appattest-environment</key>
   <string>production</string>   <!-- or development -->
   ```

   The App ID must have the App Attest capability (Xcode does it with
   automatic signing; otherwise enable it in *Certificates, Identifiers &
   Profiles*).
2. In the panel: **Developers → API keys → your app key → iOS**: Team ID, bundle ID and the
   environment. Development-signed builds attest in the development
   environment unless the entitlement says `production`; TestFlight and App
   Store builds use production. A mismatch fails with `wrong_environment`.
3. `ios/Podfile`: `platform :ios, '13.0'` still works (the plugin builds for
   iOS 13; App Attest itself needs **iOS 14** and is checked at run time).
   CocoaPods and Swift Package Manager are both supported.

App Attest is not available in the Simulator and in most app extensions.
Apple rate-limits new attestations per app; a gradual roll-out is wise if
millions of installs will attest on the same day.

### Debug tokens (emulators, Simulator, development builds)

On the app key, turn on **Allow debug tokens** and create a token (`cdt_…`,
shown once). Pass it as `debugToken:` in debug builds only — for example
from `--dart-define=CATZ_DEBUG_TOKEN=…` with `kReleaseMode ? null : …`. With a
debug token the SDK skips Play Integrity / App Attest and the server issues a
session marked `debug`. In a release build (`kReleaseMode`) the SDK ignores
the token (and prints a warning) and attests as usual. Anyone holding a debug
token can get sessions (at most 60 an hour per token), so revoke tokens you
no longer need, and turn debug off on keys used by production apps.

### What app keys do not protect against

- **Abuse through the genuine app** on a genuine device (someone scripting
  your app's UI, device farms): that is what the per-device, per-recipient
  and per-key limits and the template allow-list are for. Keep them tight and
  add your own checks (sign-in throttling, CAPTCHA) where it matters.
- **Who the user is**: attestation proves the app and device, not the
  person. App keys therefore cannot create calls or mint call tokens.
- **A session token copied off a device** during its lifetime (default
  1 hour): it is bound to the key and the device id and limited like the
  device, and expires on its own; "sign out all devices" on the key revokes
  every session at once.
- **Compromised devices that still pass** Play's device integrity, or a
  jailbroken iPhone with a valid App Attest key. Turn on *strong integrity*
  for Android where your users' devices support it.
- Builds outside Google Play / the App Store (side-loaded APKs fail
  `not_play_recognized` by design).

Other SDKs (TypeScript, Go, PHP, Rust) run on servers and have no
attestation: requests they make with an app key are refused with
`app_session_required`. Use server keys there.

### Migrating from an embedded server key

Apps that use server keys, the call client or the push helpers need no code
changes for 2.0.0 — the package is now a Flutter plugin, so rebuild the app
(`flutter clean` if the build caches the old plugin list; iOS runs
`pod install` / resolves the Swift package automatically). To move an app
that embeds a server key to an app key:

1. Create the app key and do the Android / iOS setup above.
2. Replace `CatzConnect(env: EnvValues(apiKey: …, …))` with
   `CatzConnect.app(appKey: …, privateKey: …, serverPublicKey: …)`.
3. Ship the update, watch the key's *Refused attempts* tab (App settings), then
   **revoke the old embedded server key** (until you do, it can still be
   extracted from older builds).

---

## Install

```yaml
dependencies:
  catzconnect: ^2.0.0
```

```sh
flutter pub get
```

Requirements: Dart 3.13+ and Flutter 3.47+ (needed by `sodium` 4.x).
Dependencies: `sodium` (^4.1.2, builds and bundles libsodium through its
build hooks), `flutter_webrtc` (^1.0.0) and `web_socket_channel` (^3.0.0). The package re-exports the WebRTC types you
need for rendering (`MediaStream`, `RTCVideoRenderer`, `RTCVideoView`,
`RTCVideoViewObjectFit`). Since 2.0.0 the package is a Flutter plugin (for
app keys): Android adds `com.google.android.play:integrity`, iOS links
`DeviceCheck`; nothing runs until you use `CatzConnect.app`.

```dart
import 'package:catzconnect/catzconnect.dart';
```

### Initialise libsodium (optional)

Everything loads libsodium on first use. To load it at start-up — and see a
missing native library straight away rather than on the first send — call:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CatzConnect.init(); // sodium SodiumInit.init() + SodiumSumoInit.init()
  runApp(const MyApp());
}
```

`CatzConnect.init()` is safe to call more than once.

## Platform notes

| Platform | `send()` / `calls.*` | Push helpers | Call client |
| --- | --- | --- | --- |
| Android, iOS, macOS, Linux, Windows | ✓ | ✓ | ✓ |
| Web | ✗ (`UnsupportedError`: they use `dart:io` `HttpClient` and native libsodium) | ✓ after `dart run sodium:update_web` | ✓ |

App keys (`CatzConnect.app`) work on Android and iOS only; elsewhere they
throw a `CatzAttestationException` with reason `unsupported_platform`.

### libsodium

`package:sodium` (4.x) builds libsodium from source with its build hooks
(native assets) and bundles it into your app on Android, iOS, macOS, Linux
and Windows; there is nothing to install. The first build needs a C
toolchain on the build machine (Xcode command line tools on macOS, the
Android NDK for Android, `make` and a C compiler on Linux; on Windows,
cross-compiling for Android needs Git Bash and `make`).

- **Upgrading from 1.x** (which used the discontinued
  `sodium_libs`): remove `sodium_libs` from your own `pubspec.yaml` if you
  added it, then `flutter clean && flutter pub get`. On iOS / macOS also
  delete `ios/Pods` (or `macos/Pods`) and `Podfile.lock` and run
  `pod install` again.
- **Web** (push helpers only): download sodium.js into `web/` once:

  ```sh
  dart run sodium:update_web
  ```

`send()` and `calls.*` use `crypto_aead_chacha20poly1305_ietf` through
`package:sodium`'s FFI bindings on the bundled libsodium (the high-level `sodium` API only wraps the original 8-byte-nonce
ChaCha20-Poly1305), plus `crypto_scalarmult` and `crypto_generichash` from
the Sumo API. The output is byte-identical to the other SDKs; the tests check
this against vectors produced by the TypeScript SDK.

### Android (calls)

`android/app/src/main/AndroidManifest.xml`:

```xml
<uses-feature android:name="android.hardware.camera" android:required="false" />
<uses-feature android:name="android.hardware.camera.autofocus" android:required="false" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.MODIFY_AUDIO_SETTINGS" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.CHANGE_NETWORK_STATE" />
<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN" android:maxSdkVersion="30" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
```

`INTERNET` is also what `send()` needs. `android/app/build.gradle`: set
`minSdkVersion 23` (or higher) and Java 8+ compile options, as
`flutter_webrtc` requires.

On Android 6+ the user must also grant camera and microphone permission at
runtime. `getUserMedia` asks for it the first time. If you use a permission
plugin you can ask earlier.

**Screen sharing** (`shareScreen()`) uses MediaProjection. On Android 10+
you must run a foreground service of type `mediaProjection` before calling
it, and on Android 14+ you also need the `FOREGROUND_SERVICE` and
`FOREGROUND_SERVICE_MEDIA_PROJECTION` permissions. This package does not
start that service for you.

### iOS (calls)

`ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>$(PRODUCT_NAME) uses the camera for video calls.</string>
<key>NSMicrophoneUsageDescription</key>
<string>$(PRODUCT_NAME) uses the microphone for calls.</string>
<key>UIBackgroundModes</key>
<array>
  <string>audio</string>
</array>
```

In `ios/Podfile`, use `platform :ios, '13.0'` or higher.

Not included: **CallKit and PushKit (VoIP push)**. Without them iOS shows
a ringing call only as a normal notification, and the app has to be opened
to answer. If you need the native incoming-call screen, use a CallKit plugin
and feed its accept/decline actions into `accept()` / `decline()`. Screen
sharing on iOS needs a ReplayKit broadcast extension and is not supported
out of the box.

### Web / desktop (calls)

These work through `flutter_webrtc`. Browsers require HTTPS (or localhost)
for camera and microphone access.

---

## send()

Read the [security warning](#️-security-warning-keys-inside-an-app-are-public)
first. Credentials come from `EnvValues` (on the client or per call) or from
`--dart-define` / the process environment: `CATZCONNECT_API_KEY`,
`CATZCONNECT_PRIVATE_KEY`, `CATZCONNECT_SERVER_PUBLIC_KEY`, and the optional
`CATZCONNECT_BASE_URL` (default `https://api.catzconnect.com`; a trailing
slash is removed). The base URL must be `https://`: plain `http://` is
accepted only for `localhost`, `127.0.0.1`, `[::1]` and `10.0.2.2` (the
Android emulator's host); any other `http://` URL makes requests throw a
`CatzException` before anything is sent, since the API key would travel
unencrypted. To allow it anyway pass `allowInsecureHttp: true` to
`CatzConnect(...)` / `CatzConnect.app(...)` or set
`CATZCONNECT_ALLOW_INSECURE_HTTP=1`. `EnvValues.toString()` never prints
the API key or the private key. Keys are read leniently: surrounding whitespace, a
trailing newline, URL-safe base64 and missing padding are accepted.

```dart
final catz = CatzConnect(
  env: EnvValues(apiKey: apiKey, privateKey: privateKey, serverPublicKey: serverPublicKey),
  // baseUrl: 'https://api.catzconnect.com',
  // timeout: const Duration(seconds: 30),
  // defaultLanguage: 'de', // used when a SendInput has no language
);
// or the ready-made `catzconnect`, which reads the CATZCONNECT_* values.
```

Every request posts `{nonce, ciphertext}` to `/sdk/send` with
`Authorization: Bearer <api key>`: the payload plus `ts` (milliseconds) as
JSON, sealed with ChaCha20-Poly1305 (IETF) under a key derived as X25519 →
BLAKE2b-256 → BLAKE2b-256(master ‖ `CONNECT-@-2026-HS-@-CATZ`).

### Language of the default OTP templates

`SendInput.language` (optional) picks the language of the **built-in**
Otp/Verification templates for Email, SMS, Voice and WhatsApp: `en`, `de`,
`ja`, `ar` or `hi`. A BCP-47 tag such as `'de-DE'` is accepted and sent as
`'de'`, at the top level of the request next to `channel`/`template`.
Anything else throws a `CatzValidationException` before the request
(`Unsupported 'language' "fr": use one of en, de, ja, ar, hi (or a BCP-47 tag
such as de-DE)`). `null` leaves the field out (the server uses English, as
before) unless the client was made with `defaultLanguage`. Templates you
created in the panel are not affected. `normaliseLanguage`,
`isValidLanguage` and `kSupportedLanguages` are exported.

### Email

```dart
// A one-time code (6 digits).
await catz.send(const SendInput(
  channel: Channel.email,
  type: MessageType.verification,
  template: Template.otp,
  identity: 'noreply@yourdomain.com', // a mailbox this key may send from
  payload: SendPayload(to: 'user@example.com', otp: '123456'),
));

// The same code with the default template in German ('de-DE' is sent as 'de').
await catz.send(const SendInput(
  channel: Channel.email,
  type: MessageType.verification,
  template: Template.otp,
  identity: 'noreply@yourdomain.com',
  language: 'de-DE',
  payload: SendPayload(to: 'user@example.com', otp: '123456'),
));

// Your own subject and body.
await catz.send(const SendInput(
  channel: Channel.email,
  type: MessageType.transactional,
  template: Template.custom,
  identity: 'noreply@yourdomain.com',
  payload: SendPayload(to: 'user@example.com', subject: 'Your receipt', body: 'Thanks for your order.'),
));

// A template from the panel, filled from data.
await catz.send(const SendInput(
  channel: Channel.email,
  type: MessageType.transactional,
  template: 'welcome',
  identity: 'noreply@yourdomain.com',
  payload: SendPayload(to: 'user@example.com', data: {'name': 'Ada'}),
));
```

### WhatsApp

```dart
await catz.send(const SendInput(
  channel: Channel.whatsApp,
  type: MessageType.verification,
  template: Template.otp,
  identity: '919578456444', // your connected number
  payload: SendPayload(to: '+91 98765 43210', otp: '123456'), // up to 15 letters or digits
));

// The Authentication template in Hindi: the server passes Meta the matching
// language code, so the template must be approved in that language on your
// WhatsApp Business Account, or Meta rejects the message.
await catz.send(const SendInput(
  channel: Channel.whatsApp,
  type: MessageType.verification,
  template: Template.otp,
  identity: '919578456444',
  language: 'hi',
  payload: SendPayload(to: '+91 98765 43210', otp: '123456'),
));

await catz.send(const SendInput(
  channel: Channel.whatsApp,
  type: MessageType.transactional,
  template: Template.custom,
  identity: '919578456444',
  payload: SendPayload(
    to: '+91 98765 43210',
    subject: 'Order shipped', // optional: sent as a bold first line
    body: 'Your order arrives Friday.',
  ),
));
```

### Push

```dart
// One device, sealed so only that device can read it.
await catz.send(SendInput(
  channel: Channel.push,
  type: MessageType.notification,
  template: Template.notification,
  identity: 'my-firebase-project', // the Firebase project ID
  payload: SendPayload(
    to: fcmToken,
    title: 'Inbox',
    body: 'You have mail',
    data: {'order': '42'},
    image: 'https://example.com/i.png',
    link: 'https://example.com/inbox',
    deviceKey: devicePublicKey, // from generateDeviceKeys() on that device
  ),
));

// Every device registered for a user (POST /push/register).
await catz.send(const SendInput(
  channel: Channel.push,
  type: MessageType.notification,
  template: Template.notification,
  identity: 'my-firebase-project',
  payload: SendPayload(externalUserId: 'user-77', body: 'Hi'),
));
```

### SMS

```dart
final res = await catz.send(const SendInput(
  channel: Channel.sms,
  type: MessageType.verification,
  template: Template.otp, // matched case-insensitively
  payload: SendPayload(to: '+14155550100', otp: '482913'),
));
print('${res.sms?.messageId} ${res.sms?.segments} ${res.sms?.encoding}'); // queued, not yet delivered

// The default OTP text in Japanese.
await catz.send(const SendInput(
  channel: Channel.sms,
  type: MessageType.verification,
  template: Template.otp,
  language: 'ja',
  payload: SendPayload(to: '+819012345678', otp: '482913'),
));

// Custom text: Transactional or Promotional. India (+91) needs a DLT template id.
await catz.send(const SendInput(
  channel: Channel.sms,
  type: MessageType.transactional,
  template: Template.custom,
  payload: SendPayload(
    to: '+919876543210',
    body: 'Your order has shipped',
    dltTemplateId: '1207161234567890123',
    gateway: 'msg91-main', // optional: one of the key's gateways
    sender: 'CATZIN',      // optional, only with gateway
  ),
));

// The server's length rules, before you send:
final a = analyseSms('Your code is 482913'); // encoding gsm7/ucs2, units, segments, chars
normaliseE164(' +91 98765-43210 ');          // '+919876543210' (null when not E.164)
isValidSmsSender('CATZIN');                  // true
isValidDltId('1207161234567890123');         // true
```

### Voice (phone calls)

```dart
// A code read out digit by digit.
final res = await catz.send(const SendInput(
  channel: Channel.voice,
  type: MessageType.verification,
  template: Template.otp,
  payload: SendPayload(
    to: '+14155550100',
    otp: '482913',
    data: {'language': 'en-US', 'voice': 'female', 'repeat': '2'},
  ),
));
print(res.voice?.messageId); // voice.* webhook events carry it

// The default OTP script in Arabic; the TTS language and voice follow it.
// data['language'], when given, still overrides the spoken language.
await catz.send(const SendInput(
  channel: Channel.voice,
  type: MessageType.verification,
  template: Template.otp,
  language: 'ar',
  payload: SendPayload(to: '+971501234567', otp: '482913'),
));

// Your own text (≤ 1,000 characters) through one named provider.
await catz.send(const SendInput(
  channel: Channel.voice,
  type: MessageType.notification,
  template: Template.custom,
  payload: SendPayload(to: '+919876543210', body: 'Your table is ready.', provider: 'Exotel India'),
));
```

`SendInput.fromJson({...})` also reads the same map the other SDKs take
(`channel`, `type`, `template`, `identity`, `language`, `payload` with `device_key`,
`external_user_id`, `dlt_template_id`), matching channel and type
case-insensitively.

### Errors

```dart
try {
  await catz.send(input);
} on CatzValidationException catch (e) {
  // refused before sending; the same sentence as the TypeScript SDK
} on CatzApiException catch (e) {
  // the server refused: e.status, e.code (plan_required, provider_not_allowed, …), e.body
  // e.message is "Failed to send <type>.<channel>.<template>: HTTP <status>: <body>"
} on CatzException catch (e) {
  // missing or malformed keys, or the request did not reach the server
} on UnsupportedError {
  // Flutter web
}
```

`CatzApiError` is an alias of `CatzApiException` (the TypeScript name). A
429 is a `CatzRateLimitException` (a `CatzApiException` with `retryAfter`
and `limit`). App keys add `CatzAttestationException` (see
[App key errors](#app-key-errors)).

## Calls server API

```dart
// 1. Create the call. It rings bob on every open app and, through push, his devices.
final call = await catz.calls.create(const CreateCallInput(
  mode: CallMode.video,                 // or CallMode.audio
  from: 'alice',                        // your own user ids (≤ 128 characters)
  to: ['bob'],                          // 1–49 callees, unique, not including from
  metadata: {'order': 'A-1042'},        // optional, ≤ 4 KB, delivered with "incoming"
  // engine: 'auto' | 'catz' | a provider id or label, ring: true, maxParticipants: 2–50
));

// 2. A user token for alice's app (ttlSeconds 60–86400, default 3600).
final token = await catz.calls.token('alice', ttlSeconds: 3600);
// → give call.id, token.token and token.wsUrl to alice's app

final c = await catz.calls.get(call.id);
print('${c.status} ${c.durationSecs} ${c.billedMinutes} ${c.endReason}');
for (final p in c.participants) print('${p.userId} ${p.state} ${p.seconds} ${p.connection}');

await catz.calls.end(call.id, reason: 'support_closed'); // ringing → canceled, active → ended
```

Refusals throw `CatzApiException` with the server's message, `status` and
`code` (`plan_required`, `minutes_cap_reached`, `engine_unavailable`,
`too_many_participants`, `provider_not_allowed`, …). A response with an
encrypted `{nonce, ciphertext}` envelope is opened with the request key.

## Call client

The app never sees your API key. Your backend mints a short-lived user
token (`calls.token`) and returns it to the signed-in user. The token
(`ct1.…`) carries the user id and an expiry; it stops working when the API
key that minted it is revoked.

Pass `getToken` instead of a fixed token, so long calls and reconnects can
fetch a new one by themselves:

```dart
final client = CatzCallClient(
  getToken: () async => (await myApi.get('/call-token'))['token'] as String,
  // url: ws_url from calls.token if it is not the default
);
```

### Make and answer calls

The caller's backend creates the call and gives the call id to the caller's
app. That app joins the call, and the invited users get `incoming`.

```dart
final client = CatzCallClient(getToken: fetchToken);

client.incoming.listen((IncomingCall call) {
  // show your ringing UI, then:
  // client.accept(call.callId, video: call.mode == CallMode.video);
  // or client.decline(call.callId);
});
client.remoteStreams.listen((RemoteStreamEvent e) {
  renderers[e.peer.pid]?.srcObject = e.stream;   // RTCVideoRenderer per peer
});
client.localStream.listen((LocalStreamEvent e) => localRenderer.srcObject = e.stream);
client.state.listen((CallStateEvent s) {
  if (s.status.isFinal) closeCallScreen();
});
client.errors.listen((CallError e) => log('${e.code}: ${e.message}'));

await client.connect();
final JoinResult joined = await client.join(callId, audio: true, video: true);

await client.setMuted(MediaKind.audio, true);
await client.switchCamera();
await client.shareScreen();   // where supported
await client.stopShare();
await client.cancel();        // caller hangs up while it is still ringing
await client.leave();         // hang up
await client.dispose();       // when the user signs out
```

`CatzCallClient({String? token, Future<String> Function()? getToken, String url = 'wss://api.catzconnect.com/rtc/v1/ws', bool relayOnly = false, bool allowInsecureHttp = false, bool adaptiveVideo = true, Duration healthInterval = const Duration(seconds: 2)})`

`url` must be `wss://` (`ws://` only to localhost, 127.0.0.1, ::1 or
10.0.2.2, or with `allowInsecureHttp: true`); otherwise the constructor
throws an `ArgumentError`.

| Member | Description |
| --- | --- |
| `connect()` | Opens signaling and waits for `hello`. It retries for up to 20 s, then throws `CallError('connect_failed')`. |
| `join(callId, {audio, video, stream, relayOnly})` | Joins a call. `relayOnly` overrides the client's setting for this call (see *Hiding IP addresses*). Returns a `JoinResult` with the call, your `pid`, the peers already in the call, and `provider` for provider engines. |
| `accept(callId, {...})` / `decline(callId)` | Answer or reject an incoming call. |
| `cancel([callId])` | The caller hangs up while the call is still ringing. |
| `leave()` | Hang up and release the camera and microphone. |
| `setMuted(MediaKind, bool)` | Mute or unmute without renegotiating. Turning the camera on in a call that has no camera yet opens it. |
| `switchCamera()` | Switch between front and back camera. |
| `shareScreen()` / `stopShare()` | Replace the camera with the screen. Not available on every platform. |
| `notifyNetworkChanged()` | Call this from your connectivity listener. It reconnects at once and restarts ICE. |
| `collectStats()` | Take a quality sample now. This also runs every 10 s. |
| `checkHealth()` | Run the network / CPU checks behind client warnings and adaptive video now. This also runs every `healthInterval` (2 s). |
| `activeWarnings` | The `CallWarning`s in effect for the current call. |
| `dispose()` / `close()` | Leave any call and shut the client down. |

| Stream | Payload |
| --- | --- |
| `incoming` | `IncomingCall` (callId, from, mode, engine, metadata) |
| `state` | `CallStateEvent` (ringing, active, ended, missed, declined, canceled, failed) |
| `peerJoined` / `peerLeft` | `PeerJoinedEvent` / `PeerLeftEvent` |
| `remoteStreams` | `RemoteStreamEvent`: one `MediaStream` per peer, emitted again when it gains a track |
| `localStream` | `LocalStreamEvent`: your camera/mic, the screen preview (`screen: true`), or `null` once released |
| `connection` | `ConnectionEvent`: `direct` or `relay` per peer, emitted on change |
| `quality` | `CallQuality` per peer every 10 s: rtt, jitter, loss, bitrate, level |
| `reconnecting` / `reconnected` | `scope: signaling` (WebSocket) or `scope: peer` (ICE restart) |
| `provider` | `ProviderEvent`: hand-off data when the engine is not `catz` |
| `errors` | `CallError(code, message, callId)` |
| `warnings` | `CallWarning`: something may degrade the call (see *Call warnings*); emitted once when it starts |
| `warningsCleared` | `CallWarningCleared(code, callId, source, at)`: a warning is over (also for each active warning when the call ends) |
| `closed` | The reason the client shut down |

### Ringing via push

When a callee has no open socket, the server rings them with a
**data-only** push through your organization's Push project, to the devices
registered for that external user id:

```json
{ "catz_type": "call", "call_id": "…", "from": "alice", "mode": "video", "engine": "catz" }
```

With `firebase_messaging`:

```dart
FirebaseMessaging.onMessage.listen((RemoteMessage m) async {
  final IncomingCall? call = CatzCalls.incomingFromPush(m.data);
  if (call == null) return;              // not a call push
  showRingingUi(call);                   // then:
  await client.connect();
  await client.accept(call.callId, video: call.mode == CallMode.video);
});
```

`incomingFromPush` returns `null` for any push that is not a call push, so
you can pass it every message. In a background isolate, show a local
notification and connect when the user opens the app. The call keeps
ringing until the org's ring timeout.

### Provider engines (hand-off)

If the call was created with a provider engine (`agora`, `twilio_video`,
`vonage_video`, `zoom_video`, `chime`, `livekit`, `daily`, `hms`), the client
does not open any WebRTC connections. `join()` returns
`JoinResult.provider`, and the `provider` stream emits:

```dart
client.provider.listen((ProviderEvent e) {
  // e.provider.name, room, token, appId, url, extra
  // join with that provider's Flutter SDK, then call client.leave() when done
});
```

### Reliability

- **Perfect negotiation** per pair: the participant with the
  lexicographically larger pid is polite (`polite_for` from the server
  wins). The newly joined participant offers to everyone already in the
  call. On offer glare the polite side rolls back.
- **ICE restart** when the connection stays `disconnected` for more than
  2 s, or is `failed`. Retries back off from 1 s up to 15 s. New TURN
  credentials (`joined.ice_servers` on join or resume, and `ice_refresh`) are
  applied with `setConfiguration`, without renegotiating.
- **Connection type**: taken from the selected candidate pair in `getStats`.
  If either candidate is a relay, the type is `relay`. A `stats` frame goes
  to the server every 10 s.
- **Signaling**: the client answers `ping` with `pong`, and treats 45 s
  without any frame as a dead socket. Reconnects use exponential backoff
  (0.5 s to 15 s, jitter in [d/2, d]). Signals are queued while the socket
  is down. If `getToken` is set, a fresh token is fetched when the old one
  expires or is refused. After a drop the client sends `resume` within the
  30 s grace, or joins again after it.

### Call warnings

There is no participant cap in the client: it connects to everyone the
server admits. When something may degrade the call, `warnings` emits a
`CallWarning` once, and `warningsCleared` emits when it is over (or when the
call ends); `activeWarnings` lists the ones in effect. A `CallWarning` has
`code`, `message` (English default — localise by `code`), `callId`,
`participants` (when known), `source` (`CallWarningSource.server` or
`.client`), `severity` (`info` or `warning`) and `at`.

| Code (`CallWarningCodes.…`) | Source | When |
| --- | --- | --- |
| `large_call` (`largeCall`) | server | A peer-to-peer call has many participants (the server's `CALLS_P2P_WARN_AT`, default 5); cleared when it drops below. |
| `relay_busy` (`relayBusy`) | server | The TURN relay is near capacity; cleared under 75 %. |
| `relay_unavailable` (`relayUnavailable`) | server | The relay is down or refused this participant: the call may not connect on strict networks. |
| `poor_network` (`poorNetwork`) | client | Estimated uplink below what the peers need, loss > 8 % or RTT > 600 ms, for 6 s. |
| `device_overloaded` (`deviceOverloaded`) | client | The video encoder is CPU-limited for 6 s. |
| `video_reduced` (`videoReduced`) | client, info | Adaptive video lowered the outgoing bitrate / resolution. |
| `video_paused` (`videoPaused`) | client | Video stopped (under 150 kbps per peer) to keep audio clear; cleared when it resumes. |

Codes are plain strings: newer servers may send codes this version does not
know — show `message` for those. Client warnings are emitted once on entry
and cleared after 6 s of recovery, with stricter exit thresholds (loss
< 4 %, RTT < 400 ms), so they do not flap.

```dart
const Map<String, String> texts = <String, String>{   // your translations
  CallWarningCodes.largeCall: 'Call quality may drop — many people are in this call',
  CallWarningCodes.relayUnavailable: "Calls aren't available on this network right now",
  CallWarningCodes.poorNetwork: 'Your connection is weak',
  CallWarningCodes.videoPaused: 'Your video is paused to keep audio clear',
};
List<CallWarning> active = <CallWarning>[];
client.warnings.listen((_) => setState(() => active = client.activeWarnings));
client.warningsCleared.listen((_) => setState(() => active = client.activeWarnings));

// in build():
if (active.isNotEmpty)
  MaterialBanner(
    content: Text(texts[active.last.code] ?? active.last.message),
    actions: <Widget>[TextButton(onPressed: () => setState(() => active = <CallWarning>[]), child: const Text('Dismiss'))],
  ),
```

The example app (`example/lib/call_warnings.dart`) has a complete
dismissible banner with English and German texts.

**Adaptive video** (default; `CatzCallClient(adaptiveVideo: false)` turns
it off). Every `healthInterval` (2 s) the client reads `getStats()`. In a
call with several peers it splits the estimated uplink
(`availableOutgoingBitrate`) across them — clamp(available / peers,
150 kbps, 1.5 Mbps) per peer, with `scaleResolutionDownBy` 1 · 1.5 · 2 · 3
as the budget shrinks — through `RTCRtpSender.setParameters`, and emits
`video_reduced`. Under 150 kbps per peer it pauses video
(`encodings[0].active = false`; the camera track stays, so resuming needs
no renegotiation), emits `video_paused`, and retries with backoff once the
link is calm. Audio is never touched. A 1:1 call keeps the platform's own
bitrate control unless video has to pause.

**Peer-to-peer first.** ICE uses `iceTransportPolicy: all` (unless
`relayOnly`) with the server's ICE servers in the order given — STUN first —
so a direct path is tried first and TURN is the fallback.

### Hiding IP addresses (relay-only)

By default ICE also offers this device's local and public addresses, so
the other participants can learn them. `CatzCallClient(relayOnly: true)`
(every call) or `join(callId, relayOnly: true)` / `accept(callId,
relayOnly: true)` (one call; overrides the client) sets
`iceTransportPolicy: relay`: media only flows through the TURN relay, at
the cost of some latency and relay bandwidth. It needs TURN on the server;
without TURN credentials a relay-only call cannot connect. `relayOnly` wins
over an `iceTransportPolicy` in `rtcConfig`.

## Push helpers (in the app)

End-to-end encrypted push: the device generates a keypair, keeps the
private key, and your backend sends the public key as `device_key` (or
registers it with `POST /push/register`). Catz Connect, Google and Apple
only see ciphertext.

```dart
// Once per install. Keep privateKey in secure storage (e.g. flutter_secure_storage).
final DeviceKeys keys = await generateDeviceKeys();
await myApi.registerDevice(fcmToken: token, publicKey: keys.publicKey);

FirebaseMessaging.onMessage.listen((RemoteMessage m) async {
  if (isSealedPush(m.data)) {
    final PushContent c = await openPushPayload(m.data, keys);
    showNotification(c.title, c.body, c.data, c.image, c.link);
  }
});
```

`openPushPayload` throws a `CatzException` when the message was sealed for
another key (for example after a reinstall that generated new keys without
telling your backend). `DeviceKeys.toJson()` / `DeviceKeys.fromJson()` help
you store the pair.

## Server-side helpers

These are pure Dart and synchronous; use them on your Dart backend (or any
server), **never with the secret in an app**:

```dart
// The user_hash for POST /push/register: hex HMAC-SHA256 of the user id,
// keyed with the push project's identity secret (pis_…).
final String hash = computeUserHash('user-77', identitySecret);

// A webhook's Catz-Signature header: t=<unix seconds>,v1=<hex HMAC-SHA256>.
final bool ok = verifyWebhookSignature(rawBody, request.headers['catz-signature'], 'whsec_…');
// toleranceSeconds: 300 by default; pass the body exactly as received.
```

## Migrating from catzconnect_calls

```yaml
dependencies:
  catzconnect: ^2.0.0    # was: catzconnect_calls: ^1.0.0
```

```dart
import 'package:catzconnect/catzconnect.dart'; // was: package:catzconnect_calls/catzconnect_calls.dart
```

Everything the old package exported is exported unchanged. `CallParticipant`
gained the optional `joinedAt`, `leftAt`, `seconds` and `connection` fields
that `calls.get` returns. The Dart/Flutter minimum is now 3.13 / 3.47 (for
`sodium` 4.x).

## Example app

`example/` has a minimal call app: paste a token and a call id, join, and
you get local and remote video with mute, camera and hang-up buttons.
Incoming calls ring in the app too, and call warnings show as a dismissible
banner with friendly, localisable texts (`example/lib/call_warnings.dart`). The shield button opens
`example/lib/app_key_example.dart`: attest and send an OTP with an app key
(`--dart-define=CATZ_APP_KEY=… CATZ_APP_PRIVATE_KEY=… CATZ_SERVER_PUBLIC_KEY=…`,
plus `CATZ_DEBUG_TOKEN=…` on emulators). `example/lib/server_api_examples.dart`
shows `send()` on every channel, the calls API, the push helpers and the
server-side helpers. The repository holds only `lib/` and `pubspec.yaml`,
so generate the platform folders once:

```sh
cd example
flutter create --platforms=android,ios,web .
# add the Android permissions / iOS Info.plist keys above, then
flutter run
```

## Development

```sh
flutter pub get
flutter analyze
flutter test
```

`flutter test` builds libsodium for the host through `package:sodium`'s build
hooks (a C toolchain is needed the first time) and the crypto tests use it;
they are skipped when it cannot be built or loaded. The fixed test vectors in
`test/fixtures/vectors.json` come from the TypeScript SDK:

```sh
cd ../../typescript && npm install && npm run build
node ../dart/catzconnect/tool/gen_vectors.mjs
```

## License

ISC

## Message status, retry-safe sends, test keys, hosted OTP (2.0.0)

```dart
final SendResponse res = await catz.send(SendInput(
  channel: Channel.sms, type: MessageType.transactional, template: Template.custom,
  payload: const SendPayload(to: '+919876543210', body: 'Shipped'),
  idempotencyKey: 'ship-42', reference: 'order-42'));
final Map<String, dynamic> msg = await catz.messages.get((res.data as Map)['message_id'] as String);
final Map<String, dynamic> s = await catz.otp.start(channel: 'SMS', to: '+919876543210');
await catz.otp.verify(verificationId: s['verification_id'] as String, code: typed); // throws CatzApiException (code otp_invalid, details['attempts_remaining'])
```

Keep `messages`, `otp` and `manage` on your server (they need a server key).
`catz.pushDevices.register(publishableKey: …, token: …, platform: 'android')`
uses only the project's publishable key and can run in the app. WhatsApp
approved templates: `template: 'order_update'`, `SendPayload(whatsapp: {'language': 'en_US', 'body': ['Ravi']})`.
Test keys are validated but never delivered or billed (`data['test']`,
`parseWebhookEvent(...).test`).

## Email topics, push broadcasts and topics (2.0.0)

```dart
// Push to a topic, later (server key); data['broadcast_id'] comes back.
final SendResponse res = await catz.send(SendInput(
  channel: Channel.push, type: MessageType.notification, template: Template.notification, identity: 'my-firebase',
  payload: SendPayload(body: 'Today only', push: PushOptions(topic: 'deals', sendAt: DateTime.utc(2026, 11, 2, 9))),
));
await catz.push.broadcast((res.data as Map)['broadcast_id'] as String);
// In the app, after pushDevices.register:
await catz.pushDevices.subscribeTopics(publishableKey: pk, token: fcmToken, topics: <String>['deals']);
// Email: SendPayload(topic: 'newsletter', …) — its opt-outs apply.
```

App and test keys are refused for broadcasts / topics. `kWebhookEvents`
includes `email.complained`, `email.unsubscribed`, `push.opened`,
`sms.inbound`, `sms.opt_out`, `whatsapp.opt_out`.
