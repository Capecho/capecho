/// The HTTP transport seam. The shared package stays pure Dart (no `http`/`dio` dependency, matching
/// the other `shared/` packages); the Flutter app supplies a thin adapter over `package:http`, and
/// tests supply a fake. [CapechoApi] builds the request (method, URL, headers incl. the bearer token,
/// JSON body) and parses the response — the transport only moves bytes.
abstract class HttpTransport {
  /// Perform [request] and return the raw response. Implementations should NOT throw on a non-2xx
  /// status (the client maps that to [ApiException]); they may throw on a true transport failure
  /// (no network, DNS, timeout) — that surfaces to the caller as-is.
  Future<TransportResponse> send(TransportRequest request);
}

/// An outbound HTTP request, fully built by the client.
class TransportRequest {
  const TransportRequest({
    required this.method,
    required this.url,
    required this.headers,
    this.body,
  });

  /// `GET`, `POST`, `DELETE`, `PATCH`.
  final String method;

  /// The absolute URL (base + path + encoded query string).
  final String url;

  /// Request headers (e.g. `content-type`, `authorization`).
  final Map<String, String> headers;

  /// The JSON request body as a string, or null for bodyless requests (GET/DELETE).
  final String? body;

  @override
  String toString() => 'TransportRequest($method $url)';
}

/// A raw HTTP response. [body] is the decoded text (the client parses JSON from it).
class TransportResponse {
  const TransportResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}
