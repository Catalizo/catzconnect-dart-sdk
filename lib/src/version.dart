/// The package version, sent in the `User-Agent` header.
const String kCatzConnectVersion = '1.5.0';

/// `User-Agent` for API requests (the Go, PHP and Rust SDKs send theirs too).
const String kCatzConnectUserAgent = 'catzconnect-dart-sdk/$kCatzConnectVersion';

/// The API used when neither `baseUrl` nor `CATZCONNECT_BASE_URL` is set.
const String kDefaultBaseUrl = 'https://api.catzconnect.com';
