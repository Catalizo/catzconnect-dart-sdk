// Message status, hosted OTP, the management API and the push device
// registry. Port of sdk/typescript/src/devapi.ts.

import 'core/crypto.dart';
import 'core/env.dart';
import 'core/errors.dart';
import 'core/http.dart';
import 'types.dart';

/// Machine codes the API sends in `code` ([CatzException.code]). Branch on
/// these, not on the (translated) message.
abstract final class CatzErrorCodes {
  static const String organizationSuspended = 'organization_suspended';
  static const String sendingPaused = 'sending_paused';
  static const String featureNotInPlan = 'feature_not_in_plan';
  static const String planRequired = 'plan_required';
  static const String channelLimitReached = 'channel_limit_reached';
  static const String dailyLimitReached = 'daily_limit_reached';
  static const String monthlyLimitReached = 'monthly_limit_reached';
  static const String minutesCapReached = 'minutes_cap_reached';
  static const String keyExpired = 'key_expired';
  static const String ipNotAllowed = 'ip_not_allowed';
  static const String keyRateLimited = 'key_rate_limited';
  static const String keySendLimit = 'key_send_limit';
  static const String notAllowedForAppKeys = 'not_allowed_for_app_keys';
  static const String notAllowedForTestKeys = 'not_allowed_for_test_keys';
  static const String managementScopeRequired = 'management_scope_required';
  static const String whatsappInvalidTemplate = 'whatsapp_invalid_template';
  static const String whatsappTemplateNotApproved = 'whatsapp_template_not_approved';
  static const String whatsappTemplateLanguageRequired = 'whatsapp_template_language_required';
  static const String whatsappInvalidTemplateParams = 'whatsapp_invalid_template_params';
  static const String whatsappInvalidMedia = 'whatsapp_invalid_media';
  static const String whatsappWindowClosed = 'whatsapp_window_closed';
  static const String idempotencyConflict = 'idempotency_conflict';
  static const String idempotencyInProgress = 'idempotency_in_progress';
  static const String invalidIdempotencyKey = 'invalid_idempotency_key';
  static const String invalidReference = 'invalid_reference';
  static const String messageNotFound = 'message_not_found';
  static const String otpInvalid = 'otp_invalid';
  static const String otpExpired = 'otp_expired';
  static const String otpNotFound = 'otp_not_found';
  static const String otpAlreadyVerified = 'otp_already_verified';
  static const String otpAttemptsExceeded = 'otp_attempts_exceeded';
  static const String otpResendCooldown = 'otp_resend_cooldown';
  static const String otpSendLimit = 'otp_send_limit';
  static const String unsupportedChannel = 'unsupported_channel';
  static const String unknownOperation = 'unknown_operation';
  static const String invalidRequest = 'invalid_request';
  static const String notFound = 'not_found';
  static const String conflict = 'conflict';
  static const String invalidTopic = 'invalid_topic';
  static const String topicEmailOnly = 'topic_email_only';
  static const String recipientSuppressed = 'recipient_suppressed';
  static const String whatsappOptedOut = 'whatsapp_opted_out';
  static const String notCancelable = 'not_cancelable';
  static const String notResendable = 'not_resendable';
  static const String contentGone = 'content_gone';

  /// Refusals worth retrying later with the same request.
  static bool isRetryable(String? code) =>
      code == sendingPaused ||
      code == keyRateLimited ||
      code == keySendLimit ||
      code == idempotencyInProgress ||
      code == otpResendCooldown;
}

final RegExp _uuid = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');
final RegExp _code = RegExp(r'^[A-Za-z0-9]{1,15}$');

/// Shared: encrypt, POST, return `data`.
class _SdkCaller {
  _SdkCaller(this._http, this._env);

  final CatzHttp _http;
  final EnvValues? _env;

  Future<Map<String, dynamic>> call(String path, Map<String, dynamic> body, EnvValues? env) async {
    final EnvValues? e = env ?? _env;
    final ResolvedKeys keys = resolveKeys(e);
    final EncryptedBody enc = await encryptPayload(body, keys);
    final Map<String, dynamic> res = await _http.request(path, enc, e, rebuild: () => encryptPayload(body, keys));
    final Object? data = res['data'];
    return data is Map ? Map<String, dynamic>.from(data) : res;
  }
}

// ─── message status ──────────────────────────────────────────────────────

/// The body `messages.list` posts: [recipient], [reference] and/or
/// [broadcastId] (the deliveries of one push broadcast).
Map<String, dynamic> buildListMessagesPayload({
  String? recipient,
  String? reference,
  String? broadcastId,
  String? channel,
  int? limit,
  String? before,
}) {
  final Map<String, dynamic> out = <String, dynamic>{};
  if (recipient != null && recipient.trim().isNotEmpty) out['recipient'] = recipient.trim();
  if (reference != null && reference.trim().isNotEmpty) out['reference'] = reference.trim();
  if (broadcastId != null) {
    if (!_uuid.hasMatch(broadcastId.trim())) fail("'broadcastId' must be a broadcast id (UUID)");
    out['broadcast_id'] = broadcastId.trim();
  }
  if (out.isEmpty) fail("Give 'recipient', 'reference' or 'broadcastId'");
  if (channel != null) {
    final String c = channel.toLowerCase();
    if (!<String>['email', 'sms', 'whatsapp', 'push', 'voice'].contains(c)) {
      fail("'channel' must be email, sms, whatsapp, push or voice");
    }
    out['channel'] = c;
  }
  if (limit != null) {
    if (limit < 1 || limit > 100) fail("'limit' must be from 1 to 100");
    out['limit'] = limit;
  }
  if (before != null) out['before'] = before;
  return out;
}

/// `catzconnect.messages` — status and event timeline of sent messages.
/// Answers are the server's JSON: `{message_id, channel, status,
/// provider_status, to, template, reference, key_id, test, error,
/// created_at, updated_at, events}`; `status` is normalised (queued,
/// deferred, sending, sent, delivered, read, ringing, answered, completed,
/// failed, undelivered, suppressed, bounced, complained, unknown).
class MessagesApi {
  MessagesApi(CatzHttp http, [EnvValues? env]) : _c = _SdkCaller(http, env);

  final _SdkCaller _c;

  /// One message with its `events`, by the `message_id` a send returned.
  Future<Map<String, dynamic>> get(String messageId, {EnvValues? env}) {
    if (!_uuid.hasMatch(messageId.trim())) fail("'messageId' must be a message id (UUID)");
    return _c.call('/sdk/messages/get', <String, dynamic>{'message_id': messageId.trim()}, env);
  }

  /// `{messages, next_before}`, newest first.
  Future<Map<String, dynamic>> list({
    String? recipient,
    String? reference,
    String? broadcastId,
    String? channel,
    int? limit,
    String? before,
    EnvValues? env,
  }) =>
      _c.call(
        '/sdk/messages/list',
        buildListMessagesPayload(
            recipient: recipient,
            reference: reference,
            broadcastId: broadcastId,
            channel: channel,
            limit: limit,
            before: before),
        env,
      );
}

// ─── hosted OTP ──────────────────────────────────────────────────────────

const Map<String, String> _otpChannels = <String, String>{
  'email': 'Email',
  'sms': 'SMS',
  'whatsapp': 'WhatsApp',
  'voice': 'Voice',
};

/// The body `otp.start` posts.
Map<String, dynamic> buildOtpStartPayload({
  required String channel,
  required String to,
  String? identity,
  String? template,
  String? language,
  int? codeLength,
  int? ttlSeconds,
  int? maxAttempts,
  int? resendCooldownSeconds,
  String? gateway,
  String? sender,
  String? dltTemplateId,
  String? provider,
  Map<String, Object?>? whatsapp,
  Map<String, String>? data,
  String? reference,
}) {
  final String? ch = _otpChannels[channel.toLowerCase()];
  if (ch == null) fail("'channel' must be Email, SMS, WhatsApp or Voice");
  if (to.trim().isEmpty) fail("Missing 'to'");
  final Map<String, dynamic> out = <String, dynamic>{'channel': ch, 'to': to.trim()};
  void put(String k, String? v) {
    if (v != null && v.trim().isNotEmpty) out[k] = v.trim();
  }

  put('identity', identity);
  put('template', template);
  put('language', language);
  put('gateway', gateway);
  put('sender', sender);
  put('dlt_template_id', dltTemplateId);
  put('provider', provider);
  void range(String k, int? v, int min, int max) {
    if (v == null) return;
    if (v < min || v > max) fail("'$k' must be from $min to $max");
    out[k] = v;
  }

  range('code_length', codeLength, 4, 10);
  range('ttl_seconds', ttlSeconds, 60, 3600);
  range('max_attempts', maxAttempts, 1, 10);
  range('resend_cooldown_seconds', resendCooldownSeconds, 10, 3600);
  if (whatsapp != null) out['whatsapp'] = whatsapp;
  if (data != null) out['data'] = Map<String, String>.from(data);
  put('reference', reference);
  return out;
}

/// The body `otp.verify` posts: [verificationId], or [channel] and [to].
Map<String, dynamic> buildOtpVerifyPayload({String? verificationId, String? channel, String? to, required String code}) {
  final String c = code.replaceAll(RegExp(r'[\s-]'), '');
  if (!_code.hasMatch(c)) fail("'code' must be the 1–15 letters or digits that were sent");
  if (verificationId != null) {
    if (!_uuid.hasMatch(verificationId.trim())) fail("'verificationId' must be a UUID");
    return <String, dynamic>{'verification_id': verificationId.trim(), 'code': c};
  }
  final String? ch = channel == null ? null : _otpChannels[channel.toLowerCase()];
  if (ch == null || to == null || to.trim().isEmpty) fail("Give 'verificationId', or 'channel' and 'to'");
  return <String, dynamic>{'channel': ch, 'to': to.trim(), 'code': c};
}

/// `catzconnect.otp` — hosted one-time codes: the server makes the code,
/// sends it and checks it. Refusals are [CatzApiException]s with `code`
/// `otp_invalid` (`details['attempts_remaining']`), `otp_expired`,
/// `otp_attempts_exceeded`, `otp_resend_cooldown` (`details['retry_after']`),
/// `otp_send_limit`, `otp_not_found`, `otp_already_verified`.
class OtpApi {
  OtpApi(CatzHttp http, [EnvValues? env]) : _c = _SdkCaller(http, env);

  final _SdkCaller _c;

  /// Sends a code; `code` is in the answer for test keys only.
  Future<Map<String, dynamic>> start({
    required String channel,
    required String to,
    String? identity,
    String? template,
    String? language,
    int? codeLength,
    int? ttlSeconds,
    int? maxAttempts,
    int? resendCooldownSeconds,
    String? gateway,
    String? sender,
    String? dltTemplateId,
    String? provider,
    Map<String, Object?>? whatsapp,
    Map<String, String>? data,
    String? reference,
    EnvValues? env,
  }) =>
      _c.call(
        '/sdk/otp/start',
        buildOtpStartPayload(
          channel: channel,
          to: to,
          identity: identity,
          template: template,
          language: language,
          codeLength: codeLength,
          ttlSeconds: ttlSeconds,
          maxAttempts: maxAttempts,
          resendCooldownSeconds: resendCooldownSeconds,
          gateway: gateway,
          sender: sender,
          dltTemplateId: dltTemplateId,
          provider: provider,
          whatsapp: whatsapp,
          data: data,
          reference: reference,
        ),
        env,
      );

  /// `{verified: true, …}`; a wrong code throws.
  Future<Map<String, dynamic>> verify({
    String? verificationId,
    String? channel,
    String? to,
    required String code,
    EnvValues? env,
  }) =>
      _c.call('/sdk/otp/verify',
          buildOtpVerifyPayload(verificationId: verificationId, channel: channel, to: to, code: code), env);
}

// ─── management API ──────────────────────────────────────────────────────

/// Every operation of the management API, by resource.
const Map<String, List<String>> kManageOperations = <String, List<String>>{
  'templates': <String>['list', 'get', 'save', 'delete', 'variant_save', 'variant_delete'],
  'webhooks': <String>['list', 'save', 'delete'],
  'suppressions': <String>['list', 'add', 'remove'],
  'keys': <String>['list', 'create', 'rotate', 'revoke', 'policy'],
};

/// `catzconnect.manage` — templates, webhooks, suppressions and API keys of
/// your organization. Needs a live server key with the management scope on
/// a plan with the management API. Keep it on your server.
class ManageApi {
  ManageApi(CatzHttp http, [EnvValues? env]) : _c = _SdkCaller(http, env);

  final _SdkCaller _c;

  /// Runs one operation, e.g. `call('templates', 'save', {...})`.
  Future<Map<String, dynamic>> call(String resource, String op, [Map<String, dynamic>? body, EnvValues? env]) {
    final List<String>? ops = kManageOperations[resource];
    if (ops == null || !ops.contains(op)) fail('Unknown management operation $resource/$op');
    final Map<String, dynamic> b = body ?? <String, dynamic>{};
    if (resource == 'keys' && op == 'create') {
      final Object? kind = b['kind'];
      if (kind != null && kind != 'server' && kind != 'test') fail("'kind' must be server or test");
    }
    return _c.call('/sdk/manage/$resource/$op', b, env);
  }

  /// Adds to a channel's suppression list: `email` (address), `sms` /
  /// `whatsapp` / `voice` (E.164 number) or `push` (external_user_id);
  /// [topic] (email only) limits it to one subscription topic.
  Future<Map<String, dynamic>> addSuppression(String channel, String address,
      {String? topic, String? detail, EnvValues? env}) {
    final Map<String, dynamic> b = _suppressionBody(channel, address, topic);
    if (detail != null) b['detail'] = detail;
    return call('suppressions', 'add', b, env);
  }

  /// Removes by [id], or [channel] + [address] (every topic, or [topic]).
  Future<Map<String, dynamic>> removeSuppression(
      {String? id, String? channel, String? address, String? topic, EnvValues? env}) {
    if (id != null) {
      if (!_uuid.hasMatch(id.trim())) fail("'id' must be a suppression id (UUID)");
      return call('suppressions', 'remove', <String, dynamic>{'id': id.trim()}, env);
    }
    if (address == null) fail("Give 'id' or 'address'");
    final Map<String, dynamic> b = _suppressionBody(channel, address, topic);
    return call('suppressions', 'remove', b, env);
  }

  Map<String, dynamic> _suppressionBody(String? channel, String address, String? topic) {
    if (address.trim().isEmpty) fail("Missing 'address'");
    final Map<String, dynamic> b = <String, dynamic>{'address': address.trim()};
    if (channel != null) b['channel'] = channel;
    if (topic != null) {
      final bool email = channel == null ? address.contains('@') : channel.toLowerCase() == 'email';
      if (!email) fail("'topic' applies to email suppressions only");
      if (!kEmailTopicKey.hasMatch(topic)) fail("'topic' must be a topic key");
      b['topic'] = topic;
    }
    return b;
  }
}

// ─── push broadcasts and topics (/sdk/push/*) ────────────────────────────

List<String> _pushTopics(List<String> topics, int max) {
  if (topics.isEmpty || topics.length > max) fail("'topics' must list 1–$max topic names");
  for (final String t in topics) {
    if (!kPushTopicName.hasMatch(t)) fail('A push topic is 1–64 characters of letters, digits, _ . ~ -');
  }
  return List<String>.from(topics);
}

/// The body `push.subscribe` / `push.unsubscribe` posts: registered devices
/// by [tokens] (≤ 1000) and/or every device of [externalUserId].
Map<String, dynamic> buildPushTopicChangePayload({
  required String identity,
  required String topic,
  List<String>? tokens,
  String? externalUserId,
}) {
  if (identity.trim().isEmpty) fail("Missing 'identity'");
  _pushTopics(<String>[topic], 1);
  if (tokens != null && tokens.length > 1000) fail("'tokens' must list at most 1000 tokens");
  final String? user = externalUserId?.trim();
  final bool hasTokens = tokens != null && tokens.isNotEmpty;
  if (!hasTokens && (user == null || user.isEmpty)) fail("Give 'tokens' (registered devices) or 'externalUserId'");
  return <String, dynamic>{
    'identity': identity.trim(),
    'topic': topic,
    if (hasTokens) 'tokens': List<String>.from(tokens),
    if (user != null && user.isNotEmpty) 'external_user_id': user,
  };
}

/// `catzconnect.push` — broadcasts / scheduled pushes (created by `send()`
/// with [SendPayload.push]) and push topic subscriptions, from your server
/// (server key with the Push channel; app and test keys are refused).
class PushApi {
  PushApi(CatzHttp http, [EnvValues? env]) : _c = _SdkCaller(http, env);

  final _SdkCaller _c;

  String _id(String id) {
    if (!_uuid.hasMatch(id.trim())) fail("'broadcastId' must be a broadcast id (UUID)");
    return id.trim();
  }

  /// Status and counters: `status`, `queued`, `skipped`, `over_quota`, ….
  Future<Map<String, dynamic>> broadcast(String broadcastId, {EnvValues? env}) =>
      _c.call('/sdk/push/broadcast', <String, dynamic>{'broadcast_id': _id(broadcastId)}, env);

  /// Stops one that has not finished (`not_cancelable` once it has).
  Future<Map<String, dynamic>> cancel(String broadcastId, {EnvValues? env}) =>
      _c.call('/sdk/push/cancel', <String, dynamic>{'broadcast_id': _id(broadcastId)}, env);

  /// `{topic, devices}`.
  Future<Map<String, dynamic>> subscribe({
    required String identity,
    required String topic,
    List<String>? tokens,
    String? externalUserId,
    EnvValues? env,
  }) =>
      _c.call(
          '/sdk/push/topic/subscribe',
          buildPushTopicChangePayload(identity: identity, topic: topic, tokens: tokens, externalUserId: externalUserId),
          env);

  /// `{topic, devices}`.
  Future<Map<String, dynamic>> unsubscribe({
    required String identity,
    required String topic,
    List<String>? tokens,
    String? externalUserId,
    EnvValues? env,
  }) =>
      _c.call(
          '/sdk/push/topic/unsubscribe',
          buildPushTopicChangePayload(identity: identity, topic: topic, tokens: tokens, externalUserId: externalUserId),
          env);

  /// `{topics: [{topic, devices, last_subscribed_at}]}`.
  Future<Map<String, dynamic>> topics(String identity, {EnvValues? env}) {
    if (identity.trim().isEmpty) fail("Missing 'identity'");
    return _c.call('/sdk/push/topics', <String, dynamic>{'identity': identity.trim()}, env);
  }
}

// ─── push device registry ────────────────────────────────────────────────

/// The body `pushDevices.register` posts.
Map<String, dynamic> buildRegisterDevicePayload({
  required String publishableKey,
  required String token,
  required String platform,
  String? externalUserId,
  String? userHash,
  String? appVersion,
  String? deviceKey,
}) {
  final String pk = publishableKey.trim();
  if (pk.length < 10 || pk.length > 100) fail("'publishableKey' is required");
  final String t = token.trim();
  if (t.length < 32 || t.length > 4096) fail("'token' must be the device's FCM registration token");
  if (!<String>['ios', 'android', 'web'].contains(platform)) fail("'platform' must be ios, android or web");
  final Map<String, dynamic> out = <String, dynamic>{'publishable_key': pk, 'token': t, 'platform': platform};
  if (externalUserId != null) {
    if (externalUserId.isEmpty || externalUserId.runes.length > 128) fail("'externalUserId' must be 1–128 characters");
    out['external_user_id'] = externalUserId;
  }
  if (userHash != null) out['user_hash'] = userHash;
  if (appVersion != null) {
    if (appVersion.length > 40) fail("'appVersion' is at most 40 characters");
    out['app_version'] = appVersion;
  }
  if (deviceKey != null) out['device_key'] = deviceKey;
  return out;
}

/// `catzconnect.pushDevices` — `POST /push/register`, `/push/unregister`,
/// `/push/opened` with the project's publishable key (no API key), so they
/// can run in the app itself.
class PushDevicesApi {
  PushDevicesApi(this._http);

  final CatzHttp _http;

  Map<String, dynamic> _data(Map<String, dynamic> res) {
    final Object? d = res['data'];
    return d is Map ? Map<String, dynamic>.from(d) : res;
  }

  /// Registers or refreshes this device: `{device_id, created}`.
  Future<Map<String, dynamic>> register({
    required String publishableKey,
    required String token,
    required String platform,
    String? externalUserId,
    String? userHash,
    String? appVersion,
    String? deviceKey,
  }) async =>
      _data(await _http.postPublic(
        '/push/register',
        buildRegisterDevicePayload(
          publishableKey: publishableKey,
          token: token,
          platform: platform,
          externalUserId: externalUserId,
          userHash: userHash,
          appVersion: appVersion,
          deviceKey: deviceKey,
        ),
      ));

  /// Forgets a token (sign-out): `{removed}`.
  Future<Map<String, dynamic>> unregister({required String publishableKey, required String token}) async {
    if (publishableKey.trim().length < 10) fail("'publishableKey' is required");
    if (token.trim().length < 32) fail("'token' must be the device's FCM registration token");
    return _data(await _http.postPublic(
        '/push/unregister', <String, dynamic>{'publishable_key': publishableKey.trim(), 'token': token.trim()}));
  }

  /// Subscribes this registered device to 1–20 push topics: `{topics}`
  /// (404 when the token was not registered first).
  Future<Map<String, dynamic>> subscribeTopics(
      {required String publishableKey, required String token, required List<String> topics}) async {
    if (publishableKey.trim().length < 10) fail("'publishableKey' is required");
    if (token.trim().length < 32) fail("'token' must be the device's FCM registration token");
    return _data(await _http.postPublic('/push/topics/subscribe', <String, dynamic>{
      'publishable_key': publishableKey.trim(),
      'token': token.trim(),
      'topics': _pushTopics(topics, 20),
    }));
  }

  /// Unsubscribes this registered device from push topics.
  Future<Map<String, dynamic>> unsubscribeTopics(
      {required String publishableKey, required String token, required List<String> topics}) async {
    if (publishableKey.trim().length < 10) fail("'publishableKey' is required");
    if (token.trim().length < 32) fail("'token' must be the device's FCM registration token");
    return _data(await _http.postPublic('/push/topics/unsubscribe', <String, dynamic>{
      'publishable_key': publishableKey.trim(),
      'token': token.trim(),
      'topics': _pushTopics(topics, 20),
    }));
  }

  /// Reports a notification opened (`messageId` = its `catz_id`):
  /// `{recorded, verified}`. Pass the device's FCM registration [token]
  /// whenever the app has it: the open is then verified (only the device the
  /// notification was delivered to can report it) and the first verified
  /// report fires the `push.opened` webhook. Without it the open is still
  /// recorded, but no webhook fires.
  Future<Map<String, dynamic>> opened(
      {required String publishableKey, required String messageId, String? token}) async {
    if (publishableKey.trim().length < 10) fail("'publishableKey' is required");
    if (!_uuid.hasMatch(messageId.trim())) fail("'messageId' must be the catz_id from the notification");
    final body = <String, dynamic>{'publishable_key': publishableKey.trim(), 'message_id': messageId.trim()};
    final t = token?.trim() ?? '';
    if (t.isNotEmpty) {
      if (t.length < 32 || t.length > 4096) fail("'token' must be the device's FCM registration token");
      body['token'] = t;
    }
    return _data(await _http.postPublic('/push/opened', body));
  }
}
