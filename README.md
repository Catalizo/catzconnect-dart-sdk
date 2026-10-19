# catzconnect (Flutter)

The [Catz Connect](https://catzconnect.com) SDK for Flutter, version 1.5.0, in
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

If you decide to embed a key in an app anyway (an internal tool, a kiosk, a
prototype):

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

---

## Install

```yaml
dependencies:
  catzconnect: ^1.5.0
```

```sh
flutter pub get
```

Requirements: Dart 3.9+ and Flutter 3.35+ (needed by `sodium_libs` 3.4.x).
Dependencies: `sodium_libs` (^3.4.6, bundles libsodium), `sodium` (^3.4.6,
the Dart API `sodium_libs` is built on), `flutter_webrtc` (^1.0.0) and
`web_socket_channel` (^3.0.0). The package re-exports the WebRTC types you
need for rendering (`MediaStream`, `RTCVideoRenderer`, `RTCVideoView`,
`RTCVideoViewObjectFit`).

```dart
import 'package:catzconnect/catzconnect.dart';
```

### Initialise libsodium (optional)

Everything loads libsodium on first use. To load it at start-up — and see a
missing native library straight away rather than on the first send — call:

```dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await CatzConnect.init(); // sodium_libs SodiumInit.init() + SodiumSumoInit.init()
  runApp(const MyApp());
}
```

`CatzConnect.init()` is safe to call more than once.

## Platform notes

| Platform | `send()` / `calls.*` | Push helpers | Call client |
| --- | --- | --- | --- |
| Android, iOS, macOS, Linux, Windows | ✓ | ✓ | ✓ |
| Web | ✗ (`UnsupportedError`: they use `dart:io` `HttpClient` and native libsodium) | ✓ after `sodium_libs:update_web` | ✓ |

### libsodium (sodium_libs)

`sodium_libs` ships libsodium for Android, iOS, macOS, Linux and Windows; there
is nothing to install.

- **iOS / macOS**: after upgrading, if the build cannot find libsodium,
  run `flutter clean`, delete `ios/Pods` (or `macos/Pods`) and
  `Podfile.lock`, and `pod install` again.
- **Linux**: optionally link the system libsodium instead of the bundled one
  (see the sodium_libs README, `pkg-config`).
- **Web** (push helpers only): download sodium.js into `web/` once:

  ```sh
  flutter pub run sodium_libs:update_web
  ```

`send()` and `calls.*` use `crypto_aead_chacha20poly1305_ietf` through
`package:sodium`'s FFI bindings on the libsodium that sodium_libs bundles
(the high-level `sodium` API only wraps the original 8-byte-nonce
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
slash is removed). Keys are read leniently: surrounding whitespace, a
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

`CatzApiError` is an alias of `CatzApiException` (the TypeScript name).

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

`CatzCallClient({String? token, Future<String> Function()? getToken, String url = 'wss://api.catzconnect.com/rtc/v1/ws'})`

| Member | Description |
| --- | --- |
| `connect()` | Opens signaling and waits for `hello`. It retries for up to 20 s, then throws `CallError('connect_failed')`. |
| `join(callId, {audio, video, stream})` | Joins a call. Returns a `JoinResult` with the call, your `pid`, the peers already in the call, and `provider` for provider engines. |
| `accept(callId, {...})` / `decline(callId)` | Answer or reject an incoming call. |
| `cancel([callId])` | The caller hangs up while the call is still ringing. |
| `leave()` | Hang up and release the camera and microphone. |
| `setMuted(MediaKind, bool)` | Mute or unmute without renegotiating. Turning the camera on in a call that has no camera yet opens it. |
| `switchCamera()` | Switch between front and back camera. |
| `shareScreen()` / `stopShare()` | Replace the camera with the screen. Not available on every platform. |
| `notifyNetworkChanged()` | Call this from your connectivity listener. It reconnects at once and restarts ICE. |
| `collectStats()` | Take a quality sample now. This also runs every 10 s. |
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
  catzconnect: ^1.5.0   # was: catzconnect_calls: ^1.0.0
```

```dart
import 'package:catzconnect/catzconnect.dart'; // was: package:catzconnect_calls/catzconnect_calls.dart
```

Everything the old package exported is exported unchanged. `CallParticipant`
gained the optional `joinedAt`, `leftAt`, `seconds` and `connection` fields
that `calls.get` returns. The Dart/Flutter minimum is now 3.9 / 3.35 (for
`sodium_libs`).

## Example app

`example/` has a minimal call app: paste a token and a call id, join, and
you get local and remote video with mute, camera and hang-up buttons.
Incoming calls ring in the app too. `example/lib/server_api_examples.dart`
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

`flutter test` runs on the host, where Flutter plugins (and so the libsodium
that sodium_libs bundles) are not available. The crypto tests load a system
libsodium instead — `apt install libsodium23` (Debian/Ubuntu),
`brew install libsodium` (macOS), or set `CATZ_LIBSODIUM=/path/to/libsodium.so`
— and are skipped when there is none. The fixed test vectors in
`test/fixtures/vectors.json` come from the TypeScript SDK:

```sh
cd ../../typescript && npm install && npm run build
node ../dart/catzconnect/tool/gen_vectors.mjs
```

## License

ISC
