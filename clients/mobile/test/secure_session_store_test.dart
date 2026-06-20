import 'package:capecho_mobile/auth/secure_session_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Unit tests for the mobile [SecureSessionStore] over a faked flutter_secure_storage method channel.
/// We don't exercise the real Keychain/EncryptedSharedPreferences here — we prove the store's OWN logic:
/// the empty-token guard, save/clear delegation, and the generate-once-then-stable install id.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter_secure_storage's platform channel; back it with an in-memory map.
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Map<String, String> backing;

  setUp(() {
    backing = {};
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (MethodCall call) async {
        final args = (call.arguments as Map).cast<String, dynamic>();
        switch (call.method) {
          case 'read':
            return backing[args['key'] as String];
          case 'write':
            backing[args['key'] as String] = args['value'] as String;
            return null;
          case 'delete':
            backing.remove(args['key'] as String);
            return null;
          case 'readAll':
            return Map<String, String>.from(backing);
          case 'deleteAll':
            backing.clear();
            return null;
          case 'containsKey':
            return backing.containsKey(args['key'] as String);
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      null,
    );
  });

  test('loadToken returns null when nothing is stored', () async {
    expect(await SecureSessionStore().loadToken(), isNull);
  });

  test('saveToken then loadToken round-trips the token', () async {
    final store = SecureSessionStore();
    await store.saveToken('tok-123');
    expect(await store.loadToken(), 'tok-123');
  });

  test('clear deletes the token (loadToken → null afterwards)', () async {
    final store = SecureSessionStore();
    await store.saveToken('tok-123');
    await store.clear();
    expect(await store.loadToken(), isNull);
  });

  test('an empty stored value surfaces as null, not ""', () async {
    final store = SecureSessionStore();
    await store.saveToken(''); // a corrupt/empty write…
    expect(await store.loadToken(), isNull); // …reads back as "no token"
  });

  test('installId generates once and is stable across reads', () async {
    final id = await SecureSessionStore().installId();
    expect(id, isNotEmpty);
    expect(id.length, 32); // 16 random bytes → 32 lowercase hex chars
    expect(id, matches(RegExp(r'^[0-9a-f]{32}$')));
    // A second read (fresh instance, same backing) returns the SAME id — it isn't regenerated.
    expect(await SecureSessionStore().installId(), id);
  });

  test('installId survives clear() — only the token is removed', () async {
    final store = SecureSessionStore();
    final id = await store.installId();
    await store.saveToken('tok');
    await store.clear();
    expect(await store.installId(), id);
    expect(await store.loadToken(), isNull);
  });
}
