import 'transport.dart';

CatzTransport createTransport(Duration timeout) => throw UnsupportedError(
      'CatzConnect.send() and calls.* are not available on Flutter web: they use dart:io HttpClient. '
      'Call them from your backend instead.',
    );
