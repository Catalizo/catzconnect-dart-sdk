// App keys: send a one-time code straight from the app, without a backend.
//
// An app key only works together with an app session that the server issues
// after checking Google Play Integrity (Android) or Apple App Attest (iOS),
// so a key copied out of this app is useless elsewhere. Set up the key in the
// panel (Developers → API keys → Create key → App key) and the platform steps in the
// README ("App keys"), then run with:
//
//   flutter run \
//     --dart-define=CATZ_APP_KEY=... \
//     --dart-define=CATZ_APP_PRIVATE_KEY=... \
//     --dart-define=CATZ_SERVER_PUBLIC_KEY=... \
//     --dart-define=CATZ_DEBUG_TOKEN=cdt_...   # emulators / Simulator / debug builds only

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// One client for the whole app (the session is cached inside it).
final CatzConnect appCatz = CatzConnect.app(
  appKey: const String.fromEnvironment('CATZ_APP_KEY'),
  privateKey: const String.fromEnvironment('CATZ_APP_PRIVATE_KEY'),
  serverPublicKey: const String.fromEnvironment('CATZ_SERVER_PUBLIC_KEY'),
  // Android: optional, the key's project number is used when null.
  playCloudProjectNumber: const String.fromEnvironment('CATZ_PLAY_PROJECT_NUMBER').isEmpty
      ? null
      : const String.fromEnvironment('CATZ_PLAY_PROJECT_NUMBER'),
  // Never in release builds: a debug token skips attestation.
  debugToken: kReleaseMode || const String.fromEnvironment('CATZ_DEBUG_TOKEN').isEmpty
      ? null
      : const String.fromEnvironment('CATZ_DEBUG_TOKEN'),
);

class AppKeyOtpPage extends StatefulWidget {
  const AppKeyOtpPage({super.key});

  @override
  State<AppKeyOtpPage> createState() => _AppKeyOtpPageState();
}

class _AppKeyOtpPageState extends State<AppKeyOtpPage> {
  final TextEditingController _phone = TextEditingController(text: '+14155550100');
  bool _busy = false;
  String _status = 'Not attested yet';

  @override
  void dispose() {
    _phone.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() job) async {
    setState(() => _busy = true);
    String status;
    try {
      status = await job();
    } on CatzAttestationException catch (e) {
      // e.reason: not_play_recognized, device_integrity, wrong_certificate,
      // simulator_requires_debug_token, integrity_network_error, …
      status = 'Attestation failed (${e.source.name}: ${e.reason})${e.retryable ? ' — try again later' : ''}\n'
          '${e.message}';
    } on CatzRateLimitException catch (e) {
      status = 'Limit reached (${e.limit ?? 'rate'}); retry in ${e.retryAfter?.inSeconds ?? '?'} s';
    } on CatzValidationException catch (e) {
      status = 'Refused before sending: ${e.message}';
    } on CatzApiException catch (e) {
      status = 'Server: ${e.status} ${e.code ?? ''} ${e.message}';
    } on CatzException catch (e) {
      status = e.message;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _status = status;
    });
  }

  Future<String> _attest() async {
    final CatzAppSession s = await appCatz.appSession!.ensure();
    return 'Session until ${s.expiresAt.toLocal()}${s.debug ? ' (debug token)' : ''}\n'
        'Limits: ${s.limits.perDevicePerHour ?? '-'} per device per hour, '
        'templates ${[...s.limits.allowedTypes, ...s.limits.allowedTemplates].join(', ')}';
  }

  Future<String> _sendOtp() async {
    // Generate and keep the code in your app's own flow; app keys may send
    // only the templates the key allows (by default the built-in Otp).
    final String otp = (100000 + DateTime.now().microsecondsSinceEpoch % 900000).toString();
    final SendResponse res = await appCatz.send(SendInput(
      channel: Channel.sms,
      type: MessageType.verification,
      template: Template.otp,
      payload: SendPayload(to: _phone.text.trim(), otp: otp),
    ));
    return '${res.message} (code $otp)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('App key: send an OTP')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          TextField(
            controller: _phone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(labelText: 'Phone number (E.164)'),
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              OutlinedButton(onPressed: _busy ? null : () => _run(_attest), child: const Text('Attest')),
              const SizedBox(width: 12),
              FilledButton(onPressed: _busy ? null : () => _run(_sendOtp), child: const Text('Send code')),
            ],
          ),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          SelectableText(_status),
        ],
      ),
    );
  }
}
