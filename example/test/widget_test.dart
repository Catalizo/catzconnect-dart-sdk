// Kept so `flutter create .` does not generate a default test that refers
// to a `MyApp` class this example does not have. Pumping the call page needs
// the WebRTC platform plugin, so this only checks the package wiring.

import 'package:catzconnect/catzconnect.dart';
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
}
