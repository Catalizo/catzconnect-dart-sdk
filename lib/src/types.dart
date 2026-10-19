// The send() input and response types, mirroring sdk/typescript/src/types.ts.

/// `Promotional` is accepted by the SMS and Voice channels only.
enum MessageType {
  verification('Verification'),
  transactional('Transactional'),
  promotional('Promotional'),
  notification('Notification');

  const MessageType(this.wire);

  /// The value sent to the API.
  final String wire;

  /// Parses `"Verification"`, `"verification"`, … (case-insensitive).
  static MessageType parse(String value) {
    final String v = value.trim().toLowerCase();
    for (final MessageType t in MessageType.values) {
      if (t.wire.toLowerCase() == v) return t;
    }
    throw ArgumentError.value(value, 'type', 'Unknown message type');
  }

  @override
  String toString() => wire;
}

/// The channel. `Voice` is a phone call (text-to-speech).
enum Channel {
  email('Email'),
  whatsApp('WhatsApp'),
  push('Push'),
  sms('SMS'),
  voice('Voice');

  const Channel(this.wire);

  /// The value sent to the API.
  final String wire;

  /// Parses `"Email"`, `"whatsapp"`, `"voice"`, … (case-insensitive).
  static Channel parse(String value) {
    final String v = value.trim().toLowerCase();
    for (final Channel c in Channel.values) {
      if (c.wire.toLowerCase() == v) return c;
    }
    throw ArgumentError.value(value, 'channel', 'Unknown channel');
  }

  @override
  String toString() => wire;
}

/// The built-in template names. Any other string is the name of a template
/// created in the panel (Email → Templates, or an SMS / Voice template),
/// filled from `payload.data`.
abstract final class Template {
  static const String otp = 'Otp';
  static const String custom = 'Custom';
  static const String notification = 'Notification';

  /// The names that are not panel templates.
  static const List<String> builtIn = <String>[otp, custom, notification];
}

/// What [CatzConnect.send] sends.
class SendInput {
  const SendInput({
    required this.channel,
    required this.type,
    required this.template,
    this.identity = '',
    this.payload = const SendPayload(),
    this.language,
  });

  final Channel channel;
  final MessageType type;

  /// `Template.otp`, `Template.custom`, `Template.notification`, or the name
  /// of a panel template.
  final String template;

  /// The sender identity: a mailbox for Email, your connected number for
  /// WhatsApp, the Firebase project ID for Push. Ignored by SMS and Voice.
  final String identity;

  final SendPayload payload;

  /// Language of the built-in (default) Otp/Verification templates: `en`,
  /// `de`, `ja`, `ar` or `hi`. A BCP-47 tag such as `'de-DE'` is accepted
  /// and sent as `'de'`, at the top level of the request next to
  /// channel/template. `null` leaves it out (the server's default, English)
  /// unless the client has a `defaultLanguage`. Panel templates are not
  /// affected; for Voice, `payload.data['language']` still overrides the
  /// spoken language; WhatsApp needs the Authentication template approved
  /// in that language.
  final String? language;

  /// Reads the same map the other SDKs take:
  /// `{channel, type, template, identity, payload, language}`. Channel and type are
  /// matched case-insensitively.
  factory SendInput.fromJson(Map<String, dynamic> json) {
    final Object? p = json['payload'];
    return SendInput(
      channel: Channel.parse(_str(json['channel']) ?? ''),
      type: MessageType.parse(_str(json['type']) ?? ''),
      template: _str(json['template']) ?? '',
      identity: _str(json['identity']) ?? '',
      payload: p is Map ? SendPayload.fromJson(Map<String, dynamic>.from(p)) : const SendPayload(),
      language: _str(json['language']),
    );
  }

  SendInput copyWith({
    Channel? channel,
    MessageType? type,
    String? template,
    String? identity,
    SendPayload? payload,
    String? language,
  }) =>
      SendInput(
        channel: channel ?? this.channel,
        type: type ?? this.type,
        template: template ?? this.template,
        identity: identity ?? this.identity,
        payload: payload ?? this.payload,
        language: language ?? this.language,
      );
}

/// The fields of a send. Which ones apply depends on the channel; see each
/// field. Fields left `null` are not sent.
class SendPayload {
  const SendPayload({
    this.to,
    this.otp,
    this.subject,
    this.body,
    this.title,
    this.data,
    this.image,
    this.link,
    this.deviceKey,
    this.externalUserId,
    this.gateway,
    this.sender,
    this.dltTemplateId,
    this.provider,
  });

  /// An email address for Email; a phone number with country code for
  /// WhatsApp; an E.164 number (`+919876543210`) for SMS and Voice; the FCM
  /// registration token for Push.
  final String? to;
  final String? otp;

  /// Email: required. WhatsApp: optional — sent as a bold first line.
  final String? subject;
  final String? body;

  /// Push: notification title.
  final String? title;

  /// Push: key/value pairs delivered to the app. Email, SMS or Voice with a
  /// panel template: the values for its {{variables}}. Voice: `language`
  /// (e.g. `en-US`), `voice` (`female`, `male` or a provider voice name),
  /// `repeat` (`"1"`–`"3"`).
  final Map<String, String>? data;

  /// Push: https URL of an image to show.
  final String? image;

  /// Push: https URL to open when the notification is tapped.
  final String? link;

  /// Push: the device's public key from `generateDeviceKeys()`. The
  /// notification is then sealed so only that device can read it. Sent as
  /// `device_key`.
  final String? deviceKey;

  /// Push: send to every device your app registered for this user instead of
  /// one token in [to]. Sent as `external_user_id`.
  final String? externalUserId;

  /// SMS: send through this gateway (its id or label) instead of routing.
  final String? gateway;

  /// SMS: sender override — an E.164 number or a 2–11 character sender ID.
  /// Only together with [gateway].
  final String? sender;

  /// SMS: India DLT content template id (digits). Sent as `dlt_template_id`.
  final String? dltTemplateId;

  /// Voice: call through this phone provider (its id or label).
  final String? provider;

  /// The payload as the API names its fields, without the `null` ones. The
  /// order matches the TypeScript `SendPayload` interface.
  Map<String, dynamic> toJson() => <String, dynamic>{
        if (to != null) 'to': to,
        if (otp != null) 'otp': otp,
        if (subject != null) 'subject': subject,
        if (body != null) 'body': body,
        if (title != null) 'title': title,
        if (data != null) 'data': Map<String, String>.from(data!),
        if (image != null) 'image': image,
        if (link != null) 'link': link,
        if (deviceKey != null) 'device_key': deviceKey,
        if (externalUserId != null) 'external_user_id': externalUserId,
        if (gateway != null) 'gateway': gateway,
        if (sender != null) 'sender': sender,
        if (dltTemplateId != null) 'dlt_template_id': dltTemplateId,
        if (provider != null) 'provider': provider,
      };

  /// Reads the API's field names (`device_key`, `external_user_id`,
  /// `dlt_template_id`). `data` values are turned into strings.
  factory SendPayload.fromJson(Map<String, dynamic> json) {
    Map<String, String>? data;
    final Object? d = json['data'];
    if (d is Map) {
      final Map<String, String> m = <String, String>{};
      d.forEach((Object? k, Object? v) {
        if (k != null && v != null) m[k.toString()] = v.toString();
      });
      data = m;
    }
    return SendPayload(
      to: _str(json['to']),
      otp: _str(json['otp']),
      subject: _str(json['subject']),
      body: _str(json['body']),
      title: _str(json['title']),
      data: data,
      image: _str(json['image']),
      link: _str(json['link']),
      deviceKey: _str(json['device_key']),
      externalUserId: _str(json['external_user_id']),
      gateway: _str(json['gateway']),
      sender: _str(json['sender']),
      dltTemplateId: _str(json['dlt_template_id']),
      provider: _str(json['provider']),
    );
  }
}

String? _str(Object? v) => v?.toString();

/// The server's answer: `{ success, message, data }`.
class SendResponse {
  const SendResponse({required this.success, required this.message, this.data, this.raw = const <String, dynamic>{}});

  final bool success;
  final String message;

  /// `data` as the server sent it (a map for SMS and Voice).
  final Object? data;

  /// The whole decoded response.
  final Map<String, dynamic> raw;

  factory SendResponse.fromJson(Map<String, dynamic> json) => SendResponse(
        success: json['success'] != false,
        message: json['message'] is String ? json['message'] as String : '',
        data: json['data'],
        raw: json,
      );

  /// `data` of a successful SMS send, or `null`.
  SmsSendData? get sms {
    final Object? d = data;
    return d is Map ? SmsSendData.fromJson(Map<String, dynamic>.from(d)) : null;
  }

  /// `data` of a successful Voice send, or `null`.
  VoiceSendData? get voice {
    final Object? d = data;
    return d is Map ? VoiceSendData.fromJson(Map<String, dynamic>.from(d)) : null;
  }

  @override
  String toString() => 'SendResponse(success: $success, message: $message, data: $data)';
}

/// `data` of a successful SMS send. The message is queued, not yet delivered.
class SmsSendData {
  const SmsSendData({required this.messageId, required this.segments, required this.encoding});

  /// UUID of the queued message; `sms.*` webhook events carry it.
  final String messageId;

  /// Billable parts.
  final int segments;

  /// `gsm7` or `ucs2`.
  final String encoding;

  factory SmsSendData.fromJson(Map<String, dynamic> json) {
    final Object? s = json['segments'];
    return SmsSendData(
      messageId: _str(json['message_id']) ?? '',
      segments: s is num ? s.toInt() : int.tryParse('${s ?? ''}') ?? 0,
      encoding: _str(json['encoding']) ?? '',
    );
  }
}

/// `data` of a successful Voice send. The call is queued, not yet placed.
class VoiceSendData {
  const VoiceSendData({required this.messageId, this.raw = const <String, dynamic>{}});

  /// UUID of the queued phone call; `voice.*` webhook events carry it.
  final String messageId;

  /// Every field of `data`.
  final Map<String, dynamic> raw;

  factory VoiceSendData.fromJson(Map<String, dynamic> json) =>
      VoiceSendData(messageId: _str(json['message_id']) ?? '', raw: json);
}

/// Explicit credentials, instead of the `CATZCONNECT_*` environment values.
///
/// The TypeScript SDK's `{ api_key, private_key, server_public_key }`.
class EnvValues {
  const EnvValues({required this.apiKey, required this.privateKey, required this.serverPublicKey});

  /// The API key, sent as a Bearer token.
  final String apiKey;

  /// Your private key, base64 — encrypts each request.
  final String privateKey;

  /// Catz Connect's public key, base64.
  final String serverPublicKey;
}
