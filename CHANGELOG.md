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
