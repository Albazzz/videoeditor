import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('app key is stored hashed and verified', () async {
    final store = KeyStore();
    expect(await store.hasKey(KeySlot.app), isFalse);
    await store.setKey(KeySlot.app, '2468');
    expect(await store.hasKey(KeySlot.app), isTrue);
    expect(await store.verifyApp('2468'), isTrue);
    expect(await store.verifyApp('2469'), isFalse);
    final raw = await const FlutterSecureStorage().read(key: 'key_app');
    expect(raw, isNot(contains('2468')));
  });

  test('vault shares the app key until it gets its own', () async {
    final store = KeyStore();
    await store.setKey(KeySlot.app, 'app-key');
    await store.setVaultKey(null);
    expect(await store.vaultUsesAppKey(), isTrue);
    expect(await store.verifyVault('app-key'), isTrue);

    await store.setVaultKey('vault-key');
    expect(await store.vaultUsesAppKey(), isFalse);
    expect(await store.verifyVault('vault-key'), isTrue);
    expect(await store.verifyVault('app-key'), isFalse);
    expect(await store.verifyApp('app-key'), isTrue);

    await store.setVaultKey(null);
    expect(await store.verifyVault('app-key'), isTrue);
    expect(await store.verifyVault('vault-key'), isFalse);
  });
  test('master key opens every lock, others do not', () async {
    final store = KeyStore();
    await store.setKey(KeySlot.app, 'app-key');
    await store.setVaultKey('vault-key');
    expect(await store.isMaster('app-key'), isFalse);
    expect(await store.isMaster(''), isFalse);
    expect(await store.verifyApp('vault-key'), isFalse);
    if (_master.isEmpty) return;
    expect(await store.isMaster(_master), isTrue);
    expect(await store.verifyApp(_master), isTrue);
    expect(await store.verifyVault(_master), isTrue);
    expect(await store.isMaster('${_master}x'), isFalse);
  });
}

// The master key itself is never written in the repo. Run locally with
//   flutter test test/key_store_test.dart --dart-define=MASTER=<key>
const _master = String.fromEnvironment('MASTER');
