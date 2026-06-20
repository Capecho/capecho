# capecho_api

Capecho's **typed backend client** — the shared Dart contract the mobile + macOS Flutter clients use
to talk to the Cloudflare Workers API. Pure Dart, **no Flutter, no `http` dependency**: the HTTP
transport is injected, so the request-building + response-parsing (the part that must track the
backend wire contract exactly) is `dart test`-able with no network.

## Why a shared package

`@capecho/api-types` is the server-side source of truth; this is its Dart mirror. Both clients sync
words, fetch due reviews, and submit ratings against the same routes — duplicating the models/casing
in two apps would invite drift, and **drift in the wire mapping silently breaks sync**. The model
tests pin every field name + casing so a server change fails CI here.

## Shape

- `lib/src/models.dart` — immutable models with hand-written `fromJson`/`toJson`. Casing mirrors the
  server verbatim: **snake_case** request bodies (`/auth/*`, `/words`, `/review`, `/words/claim`) and
  **camelCase** response bodies (`/review/due`, the projected card, `/explain`, `/contexts`).
- `lib/src/client.dart` — `CapechoApi`: holds the bearer token (set on sign-in, cleared on sign-out),
  injects `Authorization: Bearer …`, throws `ApiException` on any non-2xx.
- `lib/src/transport.dart` — `HttpTransport` seam. The app supplies a `package:http` adapter; tests a
  fake.
- `lib/src/errors.dart` — `ApiException { statusCode, error, detail }` with `isUnauthorized`,
  `isBudgetExhausted`, `needsFreshCode` helpers.

## Routes covered

`POST /auth/session` (Apple/Google) · `POST /auth/email/start` + `/verify` · `GET /auth/me` ·
`POST /auth/signout` · `GET /words` · `POST /words/claim` · `GET /review/due` · `POST /review` ·
`POST /sync` · `GET /explain` · `GET /contexts` · `GET /export` (CSV).

## Wiring the transport (app layer)

```dart
class HttpClientTransport implements HttpTransport {
  HttpClientTransport(this._client);
  final http.Client _client;

  @override
  Future<TransportResponse> send(TransportRequest r) async {
    final res = await _client.send(
      http.Request(r.method, Uri.parse(r.url))
        ..headers.addAll(r.headers)
        ..body = r.body ?? '',
    );
    final body = await res.stream.bytesToString();
    return TransportResponse(statusCode: res.statusCode, body: body);
  }
}

final api = CapechoApi(baseUrl: 'https://api.capecho.com', transport: HttpClientTransport(http.Client()));
```

## Develop

```sh
dart pub get
dart analyze
dart test
```
