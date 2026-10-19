// send(), calls and push helpers from Dart. Not wired into the example UI:
// read the README's security section first — these calls need your API key
// and keys, which belong on your backend, not in a shipped app.

// ignore_for_file: avoid_print

import 'package:catzconnect/catzconnect.dart';

/// Keys from `--dart-define` here; in a real app they should not be in the
/// binary at all (see the README).
final CatzConnect catz = CatzConnect(
  env: const EnvValues(
    apiKey: String.fromEnvironment('CATZCONNECT_API_KEY'),
    privateKey: String.fromEnvironment('CATZCONNECT_PRIVATE_KEY'),
    serverPublicKey: String.fromEnvironment('CATZCONNECT_SERVER_PUBLIC_KEY'),
  ),
);

Future<void> sendEveryChannel() async {
  await CatzConnect.init(); // optional: loads libsodium up front

  // Email: a one-time code.
  await catz.send(const SendInput(
    channel: Channel.email,
    type: MessageType.verification,
    template: Template.otp,
    identity: 'noreply@yourdomain.com',
    payload: SendPayload(to: 'user@example.com', otp: '123456'),
  ));

  // Email: your own subject and body.
  await catz.send(const SendInput(
    channel: Channel.email,
    type: MessageType.transactional,
    template: Template.custom,
    identity: 'noreply@yourdomain.com',
    payload: SendPayload(to: 'user@example.com', subject: 'Your receipt', body: 'Thanks for your order.'),
  ));

  // Email: a panel template by name, filled from data.
  await catz.send(const SendInput(
    channel: Channel.email,
    type: MessageType.transactional,
    template: 'welcome',
    identity: 'noreply@yourdomain.com',
    payload: SendPayload(to: 'user@example.com', data: <String, String>{'name': 'Ada'}),
  ));

  // WhatsApp.
  await catz.send(const SendInput(
    channel: Channel.whatsApp,
    type: MessageType.verification,
    template: Template.otp,
    identity: '919578456444',
    payload: SendPayload(to: '+91 98765 43210', otp: '123456'),
  ));
  await catz.send(const SendInput(
    channel: Channel.whatsApp,
    type: MessageType.transactional,
    template: Template.custom,
    identity: '919578456444',
    payload: SendPayload(to: '+91 98765 43210', subject: 'Order shipped', body: 'Your order arrives Friday.'),
  ));

  // Push to one device, sealed to its key; or to every device of a user.
  await catz.send(const SendInput(
    channel: Channel.push,
    type: MessageType.notification,
    template: Template.notification,
    identity: 'my-firebase-project',
    payload: SendPayload(
      to: 'FCM_REGISTRATION_TOKEN',
      title: 'Inbox',
      body: 'You have mail',
      data: <String, String>{'order': '42'},
      link: 'https://example.com/inbox',
      deviceKey: 'DEVICE_PUBLIC_KEY_BASE64',
    ),
  ));
  await catz.send(const SendInput(
    channel: Channel.push,
    type: MessageType.notification,
    template: Template.notification,
    identity: 'my-firebase-project',
    payload: SendPayload(externalUserId: 'user-77', body: 'Hi'),
  ));

  // SMS: a code, and a Custom text to India (DLT id required).
  final SendResponse sms = await catz.send(const SendInput(
    channel: Channel.sms,
    type: MessageType.verification,
    template: Template.otp,
    payload: SendPayload(to: '+14155550100', otp: '482913'),
  ));
  print('SMS ${sms.sms?.messageId}: ${sms.sms?.segments} segment(s), ${sms.sms?.encoding}');
  print(analyseSms('Your code is 482913')); // check the length before sending
  await catz.send(const SendInput(
    channel: Channel.sms,
    type: MessageType.transactional,
    template: Template.custom,
    payload: SendPayload(to: '+919876543210', body: 'Your order has shipped', dltTemplateId: '1207161234567890123'),
  ));

  // Voice: a phone call that reads a code out, and your own text.
  final SendResponse call = await catz.send(const SendInput(
    channel: Channel.voice,
    type: MessageType.verification,
    template: Template.otp,
    payload: SendPayload(
      to: '+14155550100',
      otp: '482913',
      data: <String, String>{'language': 'en-US', 'voice': 'female', 'repeat': '2'},
    ),
  ));
  print('Voice ${call.voice?.messageId}');
  await catz.send(const SendInput(
    channel: Channel.voice,
    type: MessageType.notification,
    template: Template.custom,
    payload: SendPayload(to: '+919876543210', body: 'Your table is ready.', provider: 'Exotel India'),
  ));
}

Future<void> callsServerApi() async {
  final Call created = await catz.calls.create(const CreateCallInput(
    mode: CallMode.video,
    from: 'alice',
    to: <String>['bob'],
    metadata: <String, Object?>{'order': 'A-1042'},
  ));
  final CallToken token = await catz.calls.token('alice', ttlSeconds: 3600);
  print('join ${created.id} with ${token.token} at ${token.wsUrl}');

  final Call c = await catz.calls.get(created.id);
  print('${c.status} ${c.durationSecs} ${c.billedMinutes} ${c.endReason}');
  await catz.calls.end(created.id, reason: 'support_closed');
}

Future<void> errors() async {
  try {
    await catz.send(const SendInput(
      channel: Channel.sms,
      type: MessageType.verification,
      template: Template.otp,
      payload: SendPayload(to: '+14155550100', otp: '482913'),
    ));
  } on CatzValidationException catch (e) {
    print('refused before sending: ${e.message}');
  } on CatzApiException catch (e) {
    print('the server said ${e.status} ${e.code}: ${e.message}');
  } on CatzException catch (e) {
    print('keys or network: ${e.message}');
  }
}

/// In the app that receives notifications.
Future<void> pushOnDevice(Map<String, dynamic> fcmData) async {
  final DeviceKeys keys = await generateDeviceKeys(); // once; keep privateKey in secure storage
  print('send ${keys.publicKey} to your backend with the FCM token');
  if (isSealedPush(fcmData)) {
    final PushContent content = await openPushPayload(fcmData, keys);
    print('${content.title}: ${content.body}');
  }
}

/// On your backend (Dart server or anywhere): never in the app.
void serverSide(String rawBody, String? signatureHeader) {
  final bool ok = verifyWebhookSignature(rawBody, signatureHeader, 'whsec_…');
  final String hash = computeUserHash('user-77', 'pis_…');
  print('$ok $hash');
}
