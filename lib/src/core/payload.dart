// Validation and payload building for send(). Port of
// sdk/typescript/src/core/payload.ts and buildSendPayload in index.ts; the
// error messages are the TypeScript SDK's, word for word.

import '../types.dart';
import '../utils/language.dart';
import '../utils/sms.dart';
import '../utils/validators.dart';
import '../utils/voice.dart';
import 'errors.dart';

final RegExp _digitsOnly = RegExp(r'^\d+$');
final RegExp _otp15 = RegExp(r'^[A-Za-z0-9]{1,15}$');

bool _empty(String? s) => s == null || s.isEmpty;

/// Throws a [CatzValidationException] when the server would refuse [input].
void verifyPayload(SendInput input) {
  // Checked first, as the TypeScript send() does before its payload checks.
  final String? language = input.language;
  if (language != null) normaliseLanguage(language);

  final MessageType type = input.type;
  final Channel channel = input.channel;
  final String template = input.template;
  final String identity = input.identity;
  final SendPayload payload = input.payload;

  if (channel == Channel.email && type == MessageType.verification && template == Template.otp) {
    if (identity.isEmpty) fail("Missing 'identity'");
    final String? to = payload.to;
    if (_empty(to)) fail("Missing 'to' in payload");
    final String? otp = payload.otp;
    if (otp == null) fail("Missing 'otp' in payload");
    validateEmail(to!);
    if (!_digitsOnly.hasMatch(otp)) fail("'otp' must contain only digits");
    if (otp.length != 6) fail("'otp' must be exactly 6 digits");
    return;
  }

  if (channel == Channel.email && type == MessageType.transactional && template == Template.custom) {
    if (identity.isEmpty) fail("Missing 'identity'");
    final String? to = payload.to;
    if (_empty(to)) fail("Missing 'to' in payload");
    if (payload.subject == null) fail("Missing 'subject' in payload");
    if (payload.body == null) fail("Missing 'body' in payload");
    validateEmail(to!);
    return;
  }

  if (channel == Channel.whatsApp && type == MessageType.verification && template == Template.otp) {
    if (identity.isEmpty) fail("Missing 'identity'");
    final String? to = payload.to;
    if (_empty(to)) fail("Missing 'to' in payload");
    validatePhone(to!);
    final String? otp = payload.otp;
    if (otp == null) fail("Missing 'otp' in payload");
    // Meta's authentication templates take up to 15 letters or digits.
    if (!_otp15.hasMatch(otp)) fail("'otp' must be up to 15 letters or digits");
    return;
  }

  if (channel == Channel.whatsApp && type == MessageType.transactional && template == Template.custom) {
    if (identity.isEmpty) fail("Missing 'identity'");
    final String? to = payload.to;
    if (_empty(to)) fail("Missing 'to' in payload");
    validatePhone(to!);
    final String? body = payload.body;
    if (_empty(body)) fail("Missing 'body' in payload");
    // Subject is optional for WhatsApp; the server sends it as a bold line.
    final String? subject = payload.subject;
    final int length = (_empty(subject) ? 0 : subject!.length + 6) + body!.length;
    if (length > 4096) fail('WhatsApp messages are limited to 4096 characters');
    return;
  }

  if (channel == Channel.push && type == MessageType.notification && template == Template.notification) {
    if (identity.isEmpty) fail("Missing 'identity' — the Firebase project ID");

    final String? to = payload.to;
    final String? user = payload.externalUserId;
    final bool hasTo = !_empty(to);
    final bool hasUser = !_empty(user);

    if (hasTo && hasUser) {
      fail("Give either 'to' (one device token) or 'external_user_id' (a user's registered devices), not both");
    }
    if (!hasTo && !hasUser) {
      fail("Missing 'to' in payload — the device's FCM registration token — or 'external_user_id' for a user's "
          'registered devices');
    }
    if (hasTo && to!.contains('@')) {
      fail("'to' must be an FCM registration token, not an email address");
    }
    if (hasUser) {
      if (user!.length > 128) fail("'external_user_id' must be a string of up to 128 characters");
      if (payload.deviceKey != null) {
        fail("'device_key' cannot be used with 'external_user_id' — each registered device's own key is used");
      }
    }

    if (_empty(payload.body)) fail("Missing 'body' in payload");

    final String? image = payload.image;
    if (image != null && !image.startsWith('https://')) fail("'image' must be an https:// URL");
    final String? link = payload.link;
    if (link != null && !link.startsWith('https://')) fail("'link' must be an https:// URL");
    // data values are Strings by type, as FCM requires.
    return;
  }

  if (channel == Channel.sms) {
    _verifySms(input);
    return;
  }

  if (channel == Channel.voice) {
    verifyVoice(input);
    return;
  }

  // An email template created in the panel, sent by name. Anything that is
  // not a built-in name; the server fills its {{variables}} from data.
  if (channel == Channel.email && !Template.builtIn.contains(template)) {
    if (identity.isEmpty) fail("Missing 'identity'");
    final String? to = payload.to;
    if (_empty(to)) fail("Missing 'to' in payload");
    validateEmail(to!);
    return;
  }

  fail('Unsupported combination: ${type.wire}.${channel.wire}.$template');
}

const List<MessageType> _smsTypes = <MessageType>[
  MessageType.verification,
  MessageType.transactional,
  MessageType.promotional,
];

String? _optional(String? v) {
  if (v == null) return null;
  final String t = v.trim();
  return t.isEmpty ? null : t;
}

/// SMS, as the server checks it: `Otp` with `Verification` and `otp`;
/// `Custom` with `Transactional`/`Promotional` and `body`; any other name is
/// an SMS template from the panel filled from `data`. Template names are
/// matched case-insensitively, as on the server. `identity` is ignored.
void _verifySms(SendInput input) {
  final MessageType type = input.type;
  final SendPayload payload = input.payload;

  final String? rawTo = payload.to;
  if (rawTo == null || rawTo.trim().isEmpty) {
    fail("Missing 'to' in payload — the recipient's number in E.164, e.g. +919876543210");
  }
  final String to = validateE164(rawTo);

  if (!_smsTypes.contains(type)) {
    fail('SMS supports type Verification (template Otp), Transactional or Promotional — not ${type.wire}');
  }

  final String? gateway = _optional(payload.gateway);
  final String? sender = _optional(payload.sender);
  if (sender != null) {
    if (gateway == null) fail("'sender' can only be used together with 'gateway'");
    if (!isValidSmsSender(sender)) fail("'sender' must be an E.164 number or a 2–11 character sender ID");
  }

  final String? dlt = _optional(payload.dltTemplateId);
  if (dlt != null && !isValidDltId(dlt)) {
    fail("'dlt_template_id' must be the numeric DLT template ID");
  }

  final String name = input.template.trim();
  if (name.isEmpty) fail("Missing 'template' — Otp, Custom, or the name of an SMS template");

  if (name.toLowerCase() == 'otp') {
    if (type != MessageType.verification) fail('template Otp goes with type Verification');
    final String? otp = payload.otp;
    if (otp == null || otp.trim().isEmpty) fail("Missing 'otp' in payload");
    if (!_otp15.hasMatch(otp.trim())) fail("'otp' must be up to 15 letters or digits");
    return;
  }

  if (name.toLowerCase() == 'custom') {
    if (type == MessageType.verification) {
      fail('type Verification goes with template Otp; use Transactional for Custom');
    }
    final String? body = payload.body;
    if (body == null || body.trim().isEmpty) fail("Missing 'body' in payload");
    validateSmsBody(body.trim());
    // India needs a DLT template id; a Custom body can only get it from the payload.
    if (to.startsWith('+91') && dlt == null) {
      fail("India (+91) requires a DLT template ID: pass 'dlt_template_id' for Custom messages");
    }
    return;
  }

  // A panel SMS template: the server renders it from data and checks its length.
}

/// The JSON body (before encryption) that `send` posts to `/sdk/send` for a
/// validated input. SMS and Voice send only their own fields; the other
/// channels pass the payload through.
Map<String, dynamic> buildSendPayload(SendInput input) {
  final Map<String, dynamic> out = _buildChannelPayload(input);
  // Top-level `language`, next to channel/template; left out when unset so
  // existing sends post the same body as before.
  final String? language = input.language;
  if (language != null) out['language'] = normaliseLanguage(language);
  return out;
}

Map<String, dynamic> _buildChannelPayload(SendInput input) {
  if (input.channel == Channel.voice) {
    return buildVoicePayload(input);
  }
  final SendPayload p = input.payload;
  if (input.channel == Channel.sms) {
    final Map<String, dynamic> out = <String, dynamic>{
      'message_type': input.type.wire,
      'channel': 'SMS',
      'template': input.template,
      'identity': input.identity, // required by the server, ignored for SMS
      if (p.to != null) 'to': p.to,
    };
    void put(String key, String? v) {
      if (v != null && v.trim().isNotEmpty) out[key] = v;
    }

    put('otp', p.otp);
    put('body', p.body);
    put('gateway', p.gateway);
    put('sender', p.sender);
    put('dlt_template_id', p.dltTemplateId);
    final Map<String, String>? data = p.data;
    if (data != null && data.isNotEmpty) out['data'] = Map<String, String>.from(data);
    return out;
  }

  return <String, dynamic>{
    'message_type': input.type.wire,
    'channel': input.channel.wire,
    'template': input.template,
    'identity': input.identity,
    ...p.toJson(),
  };
}
