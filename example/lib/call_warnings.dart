// Friendly, localisable texts for call warnings, and a dismissible banner.
//
// The SDK emits `CallWarning`s on `CatzCallClient.warnings` (and
// `warningsCleared` when they end); `activeWarnings` lists those in effect.
// Show your own text per `code` and fall back to `message` (English) for
// codes this app does not know yet (newer servers may add some).

import 'package:catzconnect/catzconnect.dart';
import 'package:flutter/material.dart';

/// Texts per warning code. Pass your own map (e.g. from your l10n files)
/// to localise; unknown codes fall back to the SDK's English `message`.
class CallWarningTexts {
  const CallWarningTexts([this.byCode = english]);

  final Map<String, String> byCode;

  static const Map<String, String> english = <String, String>{
    CallWarningCodes.largeCall: 'Call quality may drop — many people are in this call',
    CallWarningCodes.relayBusy: 'Calls are busy right now — the call may not connect on some networks',
    CallWarningCodes.relayUnavailable: "Calls aren't available on this network right now",
    CallWarningCodes.poorNetwork: 'Your connection is weak',
    CallWarningCodes.deviceOverloaded: 'Your device is busy — video quality was lowered',
    CallWarningCodes.videoReduced: 'Video quality lowered to fit your connection',
    CallWarningCodes.videoPaused: 'Your video is paused to keep audio clear',
  };

  /// Example of a second language: `CallWarningTexts(CallWarningTexts.german)`.
  static const Map<String, String> german = <String, String>{
    CallWarningCodes.largeCall: 'Die Qualität kann sinken – viele Personen sind im Anruf',
    CallWarningCodes.relayBusy: 'Anrufe sind gerade ausgelastet – in manchen Netzen klappt die Verbindung evtl. nicht',
    CallWarningCodes.relayUnavailable: 'Anrufe sind in diesem Netz gerade nicht verfügbar',
    CallWarningCodes.poorNetwork: 'Deine Verbindung ist schwach',
    CallWarningCodes.deviceOverloaded: 'Dein Gerät ist ausgelastet – die Videoqualität wurde gesenkt',
    CallWarningCodes.videoReduced: 'Videoqualität an deine Verbindung angepasst',
    CallWarningCodes.videoPaused: 'Dein Video ist pausiert, damit der Ton klar bleibt',
  };

  String textFor(CallWarning w) => byCode[w.code] ?? w.message;
}

/// The warning to show: real warnings before informational ones, newest
/// first; codes the user dismissed are skipped. Null when there is none.
CallWarning? warningToShow(List<CallWarning> active, Set<String> dismissed) {
  CallWarning? best;
  for (final CallWarning w in active) {
    if (dismissed.contains(w.code)) continue;
    if (best == null) {
      best = w;
      continue;
    }
    final bool wIsWarning = w.severity == CallWarningSeverity.warning;
    final bool bestIsWarning = best.severity == CallWarningSeverity.warning;
    if (wIsWarning && !bestIsWarning) {
      best = w;
    } else if (wIsWarning == bestIsWarning && !w.at.isBefore(best.at)) {
      best = w;
    }
  }
  return best;
}

/// A dismissible banner for one call warning.
class CallWarningBanner extends StatelessWidget {
  const CallWarningBanner({
    super.key,
    required this.warning,
    required this.onDismiss,
    this.texts = const CallWarningTexts(),
  });

  final CallWarning warning;
  final VoidCallback onDismiss;
  final CallWarningTexts texts;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool info = warning.severity == CallWarningSeverity.info;
    return MaterialBanner(
      backgroundColor: info ? scheme.secondaryContainer : scheme.errorContainer,
      leading: Icon(
        info ? Icons.info_outline : Icons.warning_amber_rounded,
        color: info ? scheme.onSecondaryContainer : scheme.onErrorContainer,
      ),
      content: Text(
        texts.textFor(warning),
        style: TextStyle(color: info ? scheme.onSecondaryContainer : scheme.onErrorContainer),
      ),
      actions: <Widget>[
        TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
      ],
    );
  }
}
