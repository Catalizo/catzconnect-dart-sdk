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

  if (payload.tracking != null && channel != Channel.email) fail("'tracking' applies to the Email channel only");
  _verifyTopicAndPush(channel, payload);
  final Map<String, Object?>? wa = payload.whatsapp;
  if (wa != null && channel != Channel.whatsApp) fail("'whatsapp' applies to the WhatsApp channel only");
  final String? idem = input.idempotencyKey;
  if (idem != null) validateIdempotencyKey(idem);
  validateReference(input.reference);

  // WhatsApp media message: template Custom with whatsapp.media (any type).
  if (channel == Channel.whatsApp && template == Template.custom && wa != null && wa['media'] != null) {
    if (identity.isEmpty) fail("Missing 'identity'");
    final String? to = payload.to;
    if (_empty(to)) fail("Missing 'to' in payload");
    validatePhone(to!);
    verifyWhatsAppMedia(wa['media']);
    return;
  }

  // WhatsApp approved template, sent by its Meta name.
  if (channel == Channel.whatsApp && template != Template.otp && template != Template.custom) {
    if (type == MessageType.promotional ||
        type == MessageType.transactional ||
        type == MessageType.verification ||
        type == MessageType.notification) {
      if (!_waTemplateName.hasMatch(template)) {
        fail('A WhatsApp template name is lower-case letters, digits and underscores (the name approved at Meta)');
      }
      if (identity.isEmpty) fail("Missing 'identity'");
      final String? to = payload.to;
      if (_empty(to)) fail("Missing 'to' in payload");
      validatePhone(to!);
      final String? otp = payload.otp;
      if (otp != null && !_otp15.hasMatch(otp)) fail("'otp' must be up to 15 letters or digits");
      if (wa != null) {
        if (wa['media'] != null) {
          fail("'whatsapp.media' goes with template Custom; use 'whatsapp.header' for a template's media");
        }
        verifyWhatsAppOptions(wa);
      }
      return;
    }
  }

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
    // A broadcast / topic push has no single recipient (checked above).
    final PushOptions? po = payload.push;
    final bool many = po != null && (po.broadcast || po.topic != null);

    if (hasTo && hasUser) {
      fail("Give either 'to' (one device token) or 'external_user_id' (a user's registered devices), not both");
    }
    if (!hasTo && !hasUser && !many) {
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

/// `topic` (Email) and `push` (Push options): where they apply and their shape.
void _verifyTopicAndPush(Channel channel, SendPayload payload) {
  final String? topic = payload.topic;
  if (topic != null) {
    if (channel != Channel.email) fail("'topic' applies to the Email channel only — for push topics use push.topic");
    if (!kEmailTopicKey.hasMatch(topic)) {
      fail("'topic' must be a topic key: lower-case letters, digits, _ and -, up to 40 characters");
    }
  }
  final PushOptions? po = payload.push;
  if (po == null) return;
  if (channel != Channel.push) fail("'push' applies to the Push channel only");
  final String? pt = po.topic;
  if (po.broadcast && pt != null) fail('Give push.broadcast or push.topic, not both');
  if (pt != null && !kPushTopicName.hasMatch(pt)) fail("'push.topic' must be 1–64 characters of letters, digits, _ . ~ -");
  if (po.broadcast || pt != null) {
    if (!_empty(payload.to) || !_empty(payload.externalUserId)) {
      fail("push.broadcast and push.topic send to many devices: leave 'to' and 'external_user_id' out");
    }
    if (payload.deviceKey != null) {
      fail("'device_key' is only for one device token — registered devices use their own keys");
    }
  }
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
  final String? idem = input.idempotencyKey;
  if (idem != null) out['idempotency_key'] = validateIdempotencyKey(idem);
  final String? ref = validateReference(input.reference);
  if (ref != null) out['reference'] = ref;
  return out;
}

final RegExp _waTemplateName = RegExp(r'^[a-z0-9_]{1,512}$');
final RegExp _idemKey = RegExp(r'^[\x21-\x7e]{1,255}$');
final RegExp _controls = RegExp(r'[\x00-\x1f\x7f]');
final RegExp _mediaId = RegExp(r'^\d{1,64}$');
final RegExp _waLanguage = RegExp(r'^[A-Za-z]{2,3}(_[A-Za-z0-9]{2,4})?$');

/// An Idempotency-Key: 1–255 visible ASCII characters, no spaces. Returns it trimmed.
String validateIdempotencyKey(String key) {
  final String k = key.trim();
  if (!_idemKey.hasMatch(k)) fail("'idempotencyKey' must be 1–255 visible ASCII characters without spaces");
  return k;
}

/// A reference: up to 128 characters, no control characters. Returns it
/// trimmed, or null when blank.
String? validateReference(String? reference) {
  if (reference == null) return null;
  final String t = reference.trim();
  if (t.isEmpty) return null;
  if (t.runes.length > 128 || _controls.hasMatch(t)) {
    fail("'reference' must be up to 128 characters without line breaks or control characters");
  }
  return t;
}

void _mediaRef(String kind, Map<Object?, Object?> m, String where) {
  final Object? rawLink = m['link'];
  final Object? rawId = m['id'];
  final String? link = rawLink is String && rawLink.isNotEmpty ? rawLink : null;
  final String? id = rawId is String && rawId.isNotEmpty ? rawId : null;
  if ((link == null) == (id == null)) fail("$where: give exactly one of 'link' (https) or 'id' (Meta media id)");
  if (link != null && (!link.startsWith('https://') || link.length > 2048 || link.contains(' '))) {
    fail('$where.link must be an https:// URL');
  }
  if (id != null && !_mediaId.hasMatch(id)) fail('$where.id must be a Meta media id (digits)');
  final Object? filename = m['filename'];
  if (filename != null) {
    if (kind != 'document') fail('$where.filename is for documents only');
    if (filename is! String || filename.runes.length > 240 || filename.contains('/') || filename.contains('\\')) {
      fail('$where.filename must be up to 240 characters without slashes');
    }
  }
}

/// A media message (`template: Template.custom` with `whatsapp['media']`).
void verifyWhatsAppMedia(Object? media) {
  if (media is! Map) fail("'whatsapp.media' must be a map");
  final Object? type = media['type'];
  if (type is! String || !<String>['image', 'document', 'video', 'audio'].contains(type)) {
    fail("'whatsapp.media.type' must be image, document, video or audio");
  }
  _mediaRef(type, media, "'whatsapp.media'");
  final Object? caption = media['caption'];
  if (caption != null) {
    if (type == 'audio') fail("'whatsapp.media.caption' is not allowed for audio");
    if (caption is! String || caption.runes.length > 1024) fail("'whatsapp.media.caption' is at most 1024 characters");
  }
}

void _param(Object? v, String where) {
  if (v is! String || v.trim().isEmpty || v.runes.length > 1024 || v.contains('\n') || v.contains('\t') || v.contains('     ')) {
    fail('$where must be non-empty text of up to 1024 characters without new lines, tabs or 5+ spaces in a row');
  }
}

/// Approved-template parameters (`whatsapp` of a template send).
void verifyWhatsAppOptions(Map<String, Object?> o) {
  final Object? language = o['language'];
  if (language != null && (language is! String || !_waLanguage.hasMatch(language))) {
    fail("'whatsapp.language' must be a Meta language code such as en, en_US or es_419");
  }
  final Object? header = o['header'];
  if (header != null) {
    if (header is! Map) fail("'whatsapp.header' must be a map");
    final Object? t = header['type'];
    if (t == 'text') {
      final Object? text = header['text'];
      if (text is! String || text.trim().isEmpty || text.runes.length > 60) fail("'whatsapp.header.text' must be 1–60 characters");
    } else if (t == 'image' || t == 'video' || t == 'document') {
      _mediaRef(t as String, header, "'whatsapp.header'");
    } else if (t == 'location') {
      if (header['latitude'] is! num || header['longitude'] is! num) {
        fail("'whatsapp.header' location needs latitude and longitude");
      }
    } else {
      fail("'whatsapp.header.type' must be text, image, video, document or location");
    }
  }
  final Object? body = o['body'];
  if (body is List) {
    for (int i = 0; i < body.length; i++) {
      _param(body[i], "'whatsapp.body[$i]'");
    }
  } else if (body is Map) {
    body.forEach((Object? k, Object? v) => _param(v, "'whatsapp.body.$k'"));
  } else if (body != null) {
    fail("'whatsapp.body' must be a list or a map of strings");
  }
  final Object? buttons = o['buttons'];
  if (buttons != null) {
    if (buttons is! List) fail("'whatsapp.buttons' must be a list");
    final Set<int> seen = <int>{};
    for (final Object? b in buttons) {
      if (b is! Map) fail("'whatsapp.buttons[]' must be maps");
      final Object? index = b['index'];
      if (index is! int || index < 0 || index > 9) fail("'whatsapp.buttons[].index' must be 0–9");
      if (!seen.add(index)) fail("'whatsapp.buttons' lists index $index twice");
      final Object? text = b['text'];
      final Object? code = b['code'];
      final Object? bp = b['payload'];
      switch (b['type']) {
        case 'url':
          if (text is! String || text.isEmpty || text.contains(' ') || text.length > 2000) {
            fail("A url button needs 'text': the URL suffix without spaces");
          }
        case 'quick_reply':
          if (bp != null && (bp is! String || bp.runes.length > 256)) fail("A quick_reply 'payload' is at most 256 characters");
        case 'copy_code':
          if (code is! String || code.isEmpty || code.runes.length > 20) fail("A copy_code button needs 'code' of up to 20 characters");
        case 'otp':
          if (code is! String || !_otp15.hasMatch(code)) fail("An otp button needs 'code': up to 15 letters or digits");
        default:
          fail("'whatsapp.buttons[].type' must be url, quick_reply, copy_code or otp");
      }
    }
  }
  final Object? media = o['media'];
  if (media != null) verifyWhatsAppMedia(media);
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
