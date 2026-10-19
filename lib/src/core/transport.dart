import 'transport_stub.dart' if (dart.library.io) 'transport_io.dart' as platform;

/// What came back from a POST.
class TransportResponse {
  const TransportResponse(this.status, this.body);

  final int status;
  final String body;

  bool get ok => status >= 200 && status < 300;
}

/// Sends one HTTP POST. The default uses `dart:io`'s `HttpClient`; pass your
/// own to `CatzConnect(transport: …)` to route requests elsewhere or to test.
abstract interface class CatzTransport {
  Future<TransportResponse> post(Uri url, Map<String, String> headers, String body);
}

/// The `dart:io` transport with a [timeout] for the whole request
/// (default 30 s, like the Go and PHP SDKs). Throws [UnsupportedError] on
/// the web.
CatzTransport defaultTransport({Duration timeout = const Duration(seconds: 30)}) =>
    platform.createTransport(timeout);
