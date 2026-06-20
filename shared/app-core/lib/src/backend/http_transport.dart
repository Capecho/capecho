import 'package:capecho_api/capecho_api.dart';
import 'package:http/http.dart' as http;

/// The app-layer adapter that gives `capecho_api`'s injected [HttpTransport] a real implementation
/// over `package:http`. The shared package stays pure Dart; this is the only place the macOS app
/// touches the network. Requires the `com.apple.security.network.client` entitlement (a sandboxed
/// macOS app cannot make outbound connections without it).
class HttpClientTransport implements HttpTransport {
  HttpClientTransport([http.Client? client]) : _client = client ?? http.Client();

  final http.Client _client;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final req = http.Request(request.method, Uri.parse(request.url));
    req.headers.addAll(request.headers);
    if (request.body != null) req.body = request.body!;
    final streamed = await _client.send(req);
    final res = await http.Response.fromStream(streamed);
    return TransportResponse(statusCode: res.statusCode, body: res.body);
  }

  void close() => _client.close();
}
