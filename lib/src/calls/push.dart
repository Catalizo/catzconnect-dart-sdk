import 'dart:convert';

import 'models.dart';

/// Static helpers that do not need a connected client.
class CatzCalls {
  CatzCalls._();

  /// Value of `catz_type` on call ringing pushes.
  static const String pushType = 'call';

  /// True when a push `data` map is a Catz Connect ringing notification.
  static bool isCallPush(Map<String, dynamic>? data) => incomingFromPush(data) != null;

  /// Parses the data payload of a ringing push
  /// `{ "catz_type": "call", "call_id", "from", "mode", "engine" }`.
  ///
  /// Returns `null` when the push is not a call push (so it can be passed
  /// every incoming message). Values may be strings (FCM data messages
  /// always are). A nested `data` object or JSON string is also accepted.
  static IncomingCall? incomingFromPush(Map<String, dynamic>? data) {
    if (data == null) return null;
    Map<String, dynamic> d = data;
    if (asString(d['catz_type']) == null) {
      final Object? nested = d['data'];
      Map<String, dynamic>? inner = asMap(nested);
      if (inner == null && nested is String) {
        try {
          inner = asMap(jsonDecode(nested));
        } on FormatException {
          inner = null;
        }
      }
      if (inner == null) return null;
      d = inner;
    }
    if (asString(d['catz_type'])?.toLowerCase() != pushType) return null;
    final String? callId = asString(d['call_id']);
    if (callId == null || callId.isEmpty) return null;
    final String? engine = asString(d['engine']);
    return IncomingCall(
      callId: callId,
      from: asString(d['from']) ?? '',
      mode: CallMode.parse(d['mode']),
      engine: (engine == null || engine.isEmpty) ? null : engine,
      fromPush: true,
    );
  }
}
