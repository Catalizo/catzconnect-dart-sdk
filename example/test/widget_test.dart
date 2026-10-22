// Kept so `flutter create .` does not generate a default test that refers
// to a `MyApp` class this example does not have. Pumping the call page needs
// the WebRTC platform plugin, so this only checks the package wiring.

import 'package:catzconnect/catzconnect.dart';
import 'package:catzconnect_example/call_warnings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('push payloads are recognised', () {
    final IncomingCall? call = CatzCalls.incomingFromPush(<String, dynamic>{
      'catz_type': 'call',
      'call_id': 'c1',
      'from': 'alice',
      'mode': 'video',
      'engine': 'catz',
    });
    expect(call?.mode, CallMode.video);
  });

  test('warning banner: localised text by code, English fallback, warnings before info, dismissed skipped', () {
    final DateTime t = DateTime.utc(2026);
    CallWarning w(String code, int sec, {CallWarningSeverity severity = CallWarningSeverity.warning}) => CallWarning(
          code: code,
          message: 'server text for $code',
          callId: 'c1',
          source: CallWarningSource.server,
          severity: severity,
          at: t.add(Duration(seconds: sec)),
        );
    const CallWarningTexts texts = CallWarningTexts();
    expect(texts.textFor(w('large_call', 0)), 'Call quality may drop — many people are in this call');
    expect(texts.textFor(w('brand_new', 0)), 'server text for brand_new');

    final List<CallWarning> active = <CallWarning>[
      w('large_call', 0),
      w('video_reduced', 5, severity: CallWarningSeverity.info),
      w('poor_network', 3),
    ];
    expect(warningToShow(active, <String>{})!.code, 'poor_network');
    expect(warningToShow(active, <String>{'poor_network'})!.code, 'large_call');
    expect(warningToShow(active, <String>{'poor_network', 'large_call'})!.code, 'video_reduced');
    expect(warningToShow(active, <String>{'poor_network', 'large_call', 'video_reduced'}), isNull);
  });
}
