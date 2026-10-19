import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'transport.dart';

CatzTransport createTransport(Duration timeout) => _IoTransport(timeout);

class _IoTransport implements CatzTransport {
  _IoTransport(this._timeout);

  final Duration _timeout;
  HttpClient? _client;

  HttpClient get _http => _client ??= HttpClient()..connectionTimeout = _timeout;

  @override
  Future<TransportResponse> post(Uri url, Map<String, String> headers, String body) async {
    HttpClientRequest? pending;

    Future<TransportResponse> run() async {
      final HttpClientRequest req = await _http.postUrl(url);
      pending = req;
      headers.forEach((String name, String value) => req.headers.set(name, value, preserveHeaderCase: true));
      final List<int> bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
      final HttpClientResponse res = await req.close();
      final String text = await res.transform(const Utf8Decoder(allowMalformed: true)).join();
      return TransportResponse(res.statusCode, text);
    }

    try {
      return await run().timeout(_timeout);
    } on TimeoutException {
      pending?.abort();
      throw HttpException('The request to $url timed out after ${_timeout.inSeconds} s', uri: url);
    }
  }
}
