/// The Catz Connect SDK for Flutter.
///
/// - [CatzConnect.send]: Email, WhatsApp, Push, SMS and Voice (phone call)
///   messages, encrypted end to end (X25519 + BLAKE2b + ChaCha20-Poly1305,
///   libsodium through sodium_libs).
/// - [CatzConnect.calls]: create calls, mint user tokens, read and end calls.
/// - [CatzCallClient]: the in-app voice and video call client; parse ringing
///   pushes with [CatzCalls.incomingFromPush].
/// - Push: [generateDeviceKeys], [isSealedPush], [openPushPayload].
/// - Webhooks: [verifyWebhookSignature]; server-side push: [computeUserHash].
///
/// An API key inside an app can be extracted by anyone who unpacks it. Read
/// the README's security section before you embed one.
library;

export 'package:flutter_webrtc/flutter_webrtc.dart'
    show MediaStream, MediaStreamTrack, RTCVideoRenderer, RTCVideoView, RTCVideoViewObjectFit;

// ── Voice & Video call client (unchanged from catzconnect_calls 1.0.0) ──
export 'src/calls/backoff.dart' show Backoff;
export 'src/calls/client.dart' show CatzCallClient, JoinResult, LocalStreamEvent, ProviderEvent, RemoteStreamEvent;
export 'src/calls/models.dart' hide asBool, asDouble, asInt, asList, asMap, asString;
export 'src/calls/protocol.dart'
    show
        CandidatePayload,
        ClientMessage,
        ErrorMessage,
        HelloMessage,
        IceRefreshMessage,
        IncomingMessage,
        JoinedMessage,
        PeerJoinedMessage,
        PeerLeftMessage,
        PingMessage,
        SdpPayload,
        ServerMessage,
        SignalData,
        SignalMessage,
        StateMessage,
        UnknownMessage,
        isPolite,
        tokenExpiry;
export 'src/calls/push.dart' show CatzCalls;
export 'src/calls/signaling.dart' show SocketConnector;
export 'src/calls/stats.dart' show StatsSample, qualityLevel;

// ── Server API: send() and calls ──
export 'src/calls_api.dart'
    show
        Call,
        CallProvider,
        CallToken,
        CallsApi,
        CreateCallInput,
        EndCallResult,
        buildCallTokenPayload,
        buildCreateCallPayload,
        kCallMaxCallees,
        kCallMetadataMaxBytes,
        kCallTokenTtlMax,
        kCallTokenTtlMin,
        kCallUserIdMax,
        validateCallUserId;
export 'src/client.dart' show CatzConnect, catzconnect;
export 'src/core/errors.dart' show CatzApiError, CatzApiException, CatzException, CatzValidationException;
export 'src/core/payload.dart' show buildSendPayload, verifyPayload;
export 'src/core/transport.dart' show CatzTransport, TransportResponse, defaultTransport;
export 'src/types.dart'
    show Channel, EnvValues, MessageType, SendInput, SendPayload, SendResponse, SmsSendData, Template, VoiceSendData;
export 'src/version.dart' show kCatzConnectVersion;

// ── send() language: the languages of the built-in Otp/Verification templates ──
export 'src/utils/language.dart' show isValidLanguage, kSupportedLanguages, normaliseLanguage;

// ── SMS and Voice helpers: the server's checks ──
export 'src/utils/sms.dart'
    show SmsAnalysis, SmsEncoding, analyseSms, isValidDltId, isValidSmsSender, kSmsMaxSegments, normaliseE164,
        validateE164, validateSmsBody;
export 'src/utils/voice.dart'
    show isValidVoiceLanguage, isValidVoiceName, kVoiceMaxChars, kVoiceMaxRepeat, parseVoiceRepeat, validateVoiceText,
        verifyVoice;

// ── Webhooks and server-side push ──
export 'src/core/webhook.dart' show computeUserHash, verifyWebhookSignature;

// ── Device-side end-to-end encrypted push ──
export 'src/push.dart' show DeviceKeys, PushContent, generateDeviceKeys, isSealedPush, openPushPayload;
