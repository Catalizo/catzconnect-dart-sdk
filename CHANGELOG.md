## 2.0.0 — 2026-10-22

The first release since 1.5.0. It collects the entries below that were never published separately (1.11.0, 1.10.0, 1.9.0, 1.8.0, 1.7.0, 1.6.0); read them for the details. Every Catz Connect SDK (TypeScript, Go, PHP, Rust, Dart/Flutter) is released as 2.0.0 together.

**Highlights**

- App keys for mobile apps (`CatzConnect.app`, Play Integrity / App Attest); the package is a Flutter plugin.
- Message status, retry-safe sends (`idempotencyKey`), `reference`, test keys, hosted OTP, the management API and the push device registry (`pushDevices`).
- WhatsApp approved templates and media; Email topics and tracking; push broadcasts, topics and scheduled pushes; cross-channel opt-outs.
- Calls (`CatzCallClient`): in-call chat and data messages, call warnings, adaptive video, no participant cap, relay-only ICE.
- `sodium` ^4.1.2 (drops the discontinued `sodium_libs`); https-only base URLs; `User-Agent: catzconnect-dart-sdk/2.0.0`.

**Upgrading from 1.5.x**

- The package is a Flutter plugin (Android and iOS) since the 1.6.0 entry: rebuild the app once after upgrading.
- **https only** (since the 1.6.0 entry): a plain `http://` base URL to a host other than `localhost`, `127.0.0.1`, `::1` or `10.0.2.2` is refused before a request is sent; opt in to plain http for a test server only.
- The API answers a request whose timestamp is more than 30 s off with HTTP 400 `clock_skew` (was 401): keep the sending host's clock in sync (NTP).
- Everything else is backward compatible: existing sends post the same body.

## 1.11.0 (unreleased, included in 2.0.0)

**Fixes before release.**

- `pushDevices.opened(..., token: fcmToken)`: optional device token. With it
  the open is verified and the first verified report fires `push.opened`;
  without it the open is recorded, no webhook.
- `ServerMessage` (sealed) has the same subtypes as in 1.9.0: relayed
  `chat` / `data` frames decode as `UnknownMessage`, and
  `CallMessageFrame.tryFrom(message)` reads them (`CallMessageFrame` is no
  longer a `ServerMessage` subtype). Exhaustive `switch`es over
  `ServerMessage` written for 1.9.0 keep compiling.
- In-call messages: `hello.limits` without `messages_relay` (a server from
  before in-call messages) means relay **off** (`MessageLimits.fromJson`);
  messages then go over data channels only and a send with no open channel
  fails with `no_route`. Such a server's `bad_request` "Unknown message type"
  answer to a chat / data frame is emitted on `errors` as a
  `CallMessageError` and never fails a pending join or a resume.
- A received message whose `ts` is out of `DateTime`'s range no longer
  throws: its time is the local time (`messageTime`).
- The per-peer receive rate bucket is dropped when the participant leaves.
- `buildSendPayload` has its dartdoc again.
- Ordering note: messages from one sender can arrive out of order when the
  route switches between relay and data channel; sort by `ts` when it
  matters.

**Message status, retry-safe sends, test keys, hosted OTP, management API, push device registry, WhatsApp templates.**

- `SendInput.idempotencyKey` (Idempotency-Key header + `idempotency_key`) and
  `SendInput.reference`.
- `SendPayload.whatsapp` (approved-template options, or `media` with
  `Template.custom`) and `SendPayload.tracking` (`TrackingOverride`, Email),
  checked by `verifyWhatsAppOptions` / `verifyWhatsAppMedia`.
- `catz.messages.get / list`, `catz.otp.start / verify`, `catz.manage.call`,
  `catz.pushDevices.register / unregister / opened` (publishable key, usable in
  the app).
- `CatzErrorCodes`, `CatzException.details`.
- `kWebhookEvents`, `parseWebhookEvent` (`test` is true for test-key events).

**Cross-channel opt-outs, topics and push broadcasts** (servers with per-channel suppressions):

- `SendPayload.topic` (Email subscription topic key) and `SendPayload.push`
  (`PushOptions { broadcast, topic, sendAt }`); the answer's `data` has
  `broadcast_id`. New `catzconnect.push`: `broadcast`, `cancel`, `subscribe`,
  `unsubscribe`, `topics` (server keys only).
- `pushDevices.subscribeTopics` / `unsubscribeTopics` (publishable key, in the app).
- `messages.list(broadcastId: …)`; message status carries `broadcast_id` /
  `resent_from`.
- `manage.addSuppression` / `removeSuppression` for every channel (email,
  sms, whatsapp, voice, push) with email `topic`, or by `id`.
- `CatzErrorCodes`: `invalidTopic`, `topicEmailOnly`, `recipientSuppressed`,
  `whatsappOptedOut`, `notCancelable`, `notResendable`, `contentGone`.
- `kWebhookEvents` adds `email.complained`, `email.unsubscribed`,
  `push.opened`, `sms.inbound`, `sms.opt_out`, `whatsapp.opt_out`.

## 1.10.0 (unreleased, included in 2.0.0)

**In-call chat and data messages (`CatzCallClient`).**

- `sendChat(text, {to})` and `sendData(payload, {to, reliable})` send to
  everyone in the call or to one participant (`to`: its pid) and return
  `SentCallMessage { id, ts, via, to }`. New streams `chatMessages`
  (`CallChatMessage { callId, id, from, userId, text, to, isPrivate, ts,
  via }`) and `dataMessages` (`CallDataMessage`, with `payload`). Your own
  messages are not echoed back.
- Peer-to-peer first: the side that offers opens two WebRTC data channels
  per peer before its first offer — `catz-msg` (ordered, reliable) and
  `catz-msg-u` (unordered, at most one retransmit: flutter_webrtc does not
  pass `maxRetransmits: 0`). When a target's channel is not open the message
  goes through the signaling server (`{"t":"chat"|"data"}`; read with
  `CallMessageFrame.tryFrom`, see 1.11.0); `messageTransport: MessageTransport.server` always
  uses the server. Receivers drop repeats of (sender pid, message id).
- Caps from `hello.limits` (`HelloMessage.messageLimits`, also
  `client.messageLimits`): 2000 characters per chat text, 16384 bytes of
  JSON per data payload, 5 messages/s per participant with a burst of 20.
  Sends over a cap or the rate fail with `CallMessageError`
  (`not_in_call`, `bad_request`, `message_too_large`, `rate_limited`,
  `no_route`); a refusal by the server arrives on `errors` as a
  `CallMessageError` with `messageId` (`ErrorMessage.messageId`).
- `ClientMessage.chat` / `ClientMessage.data`; unreliable data is not queued
  while signaling reconnects.
- Example app: a chat sheet with unread badge and recipient picker
  (`example/lib/call_chat.dart`) and a "wave" data message.

## 1.9.0 (unreleased, included in 2.0.0)

**Call warnings, adaptive video, no participant cap (`CatzCallClient`).**

- New streams `warnings` (`CallWarning { code, message, callId,
  participants, source, severity, at }`) and `warningsCleared`
  (`CallWarningCleared { code, callId, source, at }`), plus
  `activeWarnings`. Server codes (new `warning` / `warning_cleared`
  frames, decoded as `WarningMessage` / `WarningClearedMessage`):
  `large_call`, `relay_busy`, `relay_unavailable`. Client codes:
  `poor_network`, `device_overloaded`, `video_reduced` (info),
  `video_paused`. Codes are plain strings (`CallWarningCodes`); unknown ones
  are passed through. `kDefaultWarningMessages` holds the English texts.
- Client checks every `healthInterval` (default 2 s) from `getStats()`:
  `poor_network` when the estimated uplink is below what the peers need,
  loss > 8 % or RTT > 600 ms for 6 s; `device_overloaded` when the video
  encoder is CPU-limited for 6 s. Each is emitted once and cleared after
  6 s of recovery (stricter exit thresholds, so it does not flap).
- **Adaptive video** (default on, `adaptiveVideo: false` to opt out): in a
  peer-to-peer call the outgoing video is split across the peers —
  clamp(available / peers, 150 kbps, 1.5 Mbps) each, with
  `scaleResolutionDownBy` 1 · 1.5 · 2 · 3 — via `RTCRtpSender.setParameters`;
  under 150 kbps per peer video is paused (`encodings[0].active = false`,
  the track stays) to keep audio clear and resumed when bandwidth allows.
  Audio is never touched. A 1:1 call keeps the platform's own limits unless
  video has to pause.
- **No participant cap in the client.** It used to open sessions to at
  most `max_participants - 1` peers and emit `too_many_participants`; it now
  connects to everyone the server admits.
- P2P first is unchanged: `iceTransportPolicy: all` unless `relayOnly`,
  ICE servers in the server's order (STUN first, TURN as fallback).
- `StatsSample` gains `availableOutgoingKbps`, `remoteLossPct` and
  `cpuLimited`.
- Pure helpers exported for tests and custom UIs: `parseWarning`,
  `parseWarningCleared`, `SustainedFlag`, `networkBad`, `requiredKbps`,
  `videoBudget`, `videoTarget`, `levelFor`, `VideoAdapter`.
- Example app: a dismissible banner for active warnings with friendly,
  localisable texts (`example/lib/call_warnings.dart`).

## 1.8.0 (unreleased, included in 2.0.0)

**Dependencies.**

- Moved to `sodium` ^4.1.2 and dropped `sodium_libs`, which is discontinued.
  `sodium` 4 builds and bundles libsodium itself through build hooks (native
  assets), so the SDK no longer opens the native library by hand. The
  encryption and its output are unchanged (same test vectors).
- Minimum Dart 3.13 / Flutter 3.47 (required by `sodium` 4.1).
- Web push helpers: download sodium.js with `dart run sodium:update_web`
  (was `flutter pub run sodium_libs:update_web`).
- Upgrading: remove `sodium_libs` from your app's `pubspec.yaml` if you
  listed it, then `flutter clean && flutter pub get` (on iOS / macOS also
  reinstall the pods).
- `flutter test` builds libsodium for the host; no system libsodium or
  `CATZ_LIBSODIUM` needed any more.
- Shorter package description (pub.dev shows up to 180 characters).

## 1.7.0 (unreleased, included in 2.0.0)

**Security options.**

- **https only.** A plain `http://` base URL (`baseUrl:` or
  `CATZCONNECT_BASE_URL`) to a host other than `localhost`, `127.0.0.1`,
  `::1` or `10.0.2.2` now makes requests throw a `CatzException` before
  anything is sent (it used to send the API key in clear text). Opt in with
  `allowInsecureHttp: true` on `CatzConnect(...)` / `CatzConnect.app(...)`
  or `CATZCONNECT_ALLOW_INSECURE_HTTP=1`. The same rule applies to the call
  client's signaling `url` (`ws://`), which throws an `ArgumentError`;
  `CatzCallClient(allowInsecureHttp: true)` allows it.
- **Relay-only calls.** `CatzCallClient(relayOnly: true)` and
  `join(…, relayOnly:)` / `accept(…, relayOnly:)` force
  `iceTransportPolicy: relay`, so other participants never learn the
  device's IP addresses (needs TURN on the server). Default unchanged
  (`all`).
- `EnvValues.toString()` no longer prints the API key or the private key.

## 1.6.0 (unreleased, included in 2.0.0)

**App keys for mobile apps.** The package is now a Flutter plugin (Android
and iOS) so an app can call Catz Connect directly with an *app key*, which
only works together with a short-lived app session the server issues after a
Google Play Integrity or Apple App Attest check.

- `CatzConnect.app(appKey:, privateKey:, serverPublicKey:,
  playCloudProjectNumber:, debugToken:, …)`: requests a challenge
  (`/sdk/app/challenge`), gets a Play Integrity token (classic request,
  nonce = challenge) or an App Attest attestation (first run) / assertion
  (later; clientDataHash = SHA-256 of the challenge), exchanges it at
  `/sdk/app/session`, caches the session in memory, renews it on the next
  request within 20 % of its lifetime (≤ 5 min) of expiry, and sends
  `X-Catz-App-Session` on every request. A 401 `app_session_expired` /
  `app_session_invalid` / `app_session_required` gets a new session and is
  retried once (re-encrypted). Concurrent requests share one attestation; a
  failed renewal keeps the still-valid old session.
- iOS: the App Attest key id is stored per install and per app key
  (UserDefaults); `invalidKey` from App Attest or `unknown_key` /
  `key_exists` / `bad_signature` / `counter` / `device_mismatch` from the
  server → new key and attestation, once. `challenge_invalid` → new
  challenge, once.
- A random `device_id` per install (SharedPreferences / UserDefaults).
- Debug tokens (`debugToken:`) for emulators, the iOS Simulator and builds
  not installed from Google Play; without one the Simulator fails fast with
  `simulator_requires_debug_token` and an Android emulator's failure is
  reported as `emulator_requires_debug_token`. A debug token is ignored in
  release builds (`kReleaseMode`, with a printed warning).
- `CatzAttestationException` (`reason`, `source` device/server,
  `retryable`, `platform`, `nativeCode`) for every attestation failure;
  `CatzRateLimitException` (a `CatzApiException`) with `retryAfter` and
  `limit` for HTTP 429 on every call.
- `CatzConnect.appSession` (`ensure`, `current`, `clear`, `resetDevice`),
  `isAppKey`; `CatzAppSession`, `CatzAppLimits`, `CatzAttestPlatform` /
  `MethodChannelAttestPlatform` (method channel `catzconnect/attest`).
- Native code: Android (Kotlin) `com.google.android.play:integrity:1.4.0`,
  minSdk 23; iOS (Swift) `DCAppAttestService`, builds for iOS 13 (App
  Attest needs iOS 14, checked at run time), CocoaPods and Swift Package
  Manager. Nothing runs until `CatzConnect.app` is used: server-key apps,
  the call client and the push helpers are unchanged (rebuild the app once
  for the plugin registration).
- Example: `example/lib/app_key_example.dart` (attest and send an OTP).
- `User-Agent: catzconnect-dart-sdk/1.6.0`.

## 1.5.0

- `SendInput.language` (optional): the language of the built-in
  Otp/Verification templates for Email, SMS, Voice and WhatsApp — `en`,
  `de`, `ja`, `ar` or `hi`. BCP-47 tags such as `de-DE` are accepted and sent
  as the primary subtag (`de`), as a top-level `language` next to
  `channel`/`template`. Left out when `null`, so existing sends post the
  same body. An unsupported value throws a `CatzValidationException`
  (`Unsupported 'language' "fr": use one of en, de, ja, ar, hi (or a BCP-47
  tag such as de-DE)`), the TypeScript SDK's message. `SendInput.fromJson`
  reads `language`; `copyWith` takes it.
- `CatzConnect(defaultLanguage: …)`: used by every send whose `language` is
  `null`; validated when the client is made.
- `normaliseLanguage`, `isValidLanguage`, `kSupportedLanguages`.
- Voice `data['language']` still overrides the spoken language; WhatsApp
  needs the Authentication template approved in the chosen language.
- `User-Agent: catzconnect-dart-sdk/1.5.0`; test vectors regenerated with the
  TypeScript SDK 1.5.0 (new `*_language` sends and language validation
  cases).

## 1.4.0

The package is now **`catzconnect`**, the full Catz Connect SDK for Flutter,
versioned with the TypeScript, Go, PHP and Rust SDKs. It replaces
`catzconnect_calls` 1.0.0: change the dependency to `catzconnect: ^1.4.0` and
the import to `package:catzconnect/catzconnect.dart`. The call client API is
unchanged.

- `CatzConnect.send()` for Email, WhatsApp, Push, SMS and Voice, with the
  TypeScript SDK's validation (same error messages), payloads, defaults and
  errors (`CatzValidationException`, `CatzApiException` with `status`,
  `code` and `body`; `CatzApiError` alias). Requests are encrypted with
  X25519 → BLAKE2b → BLAKE2b(master ‖ `CONNECT-@-2026-HS-@-CATZ`) and
  ChaCha20-Poly1305 (IETF) through libsodium (`sodium_libs`), byte-identical
  to the other SDKs.
- `CatzConnect.calls`: `create`, `token`, `get`, `end`, plus
  `buildCreateCallPayload`, `buildCallTokenPayload`, `validateCallUserId` and
  the limits (`kCallMaxCallees`, `kCallUserIdMax`, `kCallMetadataMaxBytes`,
  `kCallTokenTtlMin`, `kCallTokenTtlMax`). Encrypted response envelopes are
  opened with the request key.
- SMS helpers: `analyseSms`, `normaliseE164`, `validateE164`,
  `isValidSmsSender`, `isValidDltId`, `validateSmsBody`, `kSmsMaxSegments`.
- Voice helpers: `verifyVoice`, `validateVoiceText`, `isValidVoiceLanguage`,
  `isValidVoiceName`, `parseVoiceRepeat`, `kVoiceMaxChars`, `kVoiceMaxRepeat`.
- Push: `generateDeviceKeys`, `isSealedPush`, `openPushPayload` (device
  side); `computeUserHash` (server side).
- `verifyWebhookSignature` for the `Catz-Signature` header.
- `CatzConnect.init()` loads libsodium up front (optional; everything is
  lazy).
- Configuration: `EnvValues` per client or per call, or `--dart-define` /
  process environment `CATZCONNECT_API_KEY`, `CATZCONNECT_PRIVATE_KEY`,
  `CATZCONNECT_SERVER_PUBLIC_KEY`, `CATZCONNECT_BASE_URL`. Lenient key
  decoding (whitespace, URL-safe, no padding) with a 32-byte check, a 30 s
  timeout and a `User-Agent: catzconnect-dart-sdk/1.4.0`, like the Go, PHP
  and Rust SDKs. A custom `CatzTransport` can be passed.
- `send()` and `calls.*` throw `UnsupportedError` on Flutter web (they use
  `dart:io`); the push helpers and the call client work there.
- `CallParticipant` gained optional `joinedAt`, `leftAt`, `seconds` and
  `connection` (from `calls.get`).
- Requires Dart 3.9 / Flutter 3.35 (for `sodium_libs` 3.4.x).
- Tests against fixed vectors produced by the TypeScript SDK
  (`tool/gen_vectors.mjs`), and FIPS 180-4 / RFC 4231 vectors for the
  pure-Dart SHA-256 / HMAC used by webhooks and `computeUserHash`.

## 1.0.0 (as catzconnect_calls)

- First release: `CatzCallClient` for Catz Connect voice and video calls.
  - Engine `catz`: peer-to-peer WebRTC (flutter_webrtc) with perfect
    negotiation, buffered ICE candidates, glare rollback, ICE restart with
    backoff, TURN credential refresh, and direct/relay detection.
  - Signaling WebSocket (web_socket_channel): auto-reconnect with
    exponential backoff and jitter, token refresh through `getToken`,
    ping/pong, a silence watchdog, an outgoing queue, and `resume` within
    the 30 s grace.
  - Quality samples every 10 s (`quality` stream and `stats` frames).
  - Mute, camera switch, and screen sharing where the platform supports it.
  - Provider-engine hand-off (`provider` stream / `JoinResult.provider`).
- `CatzCalls.incomingFromPush` for ringing pushes.
