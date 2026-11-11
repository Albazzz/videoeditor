import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which lock a key opens.
enum KeySlot { app, vault }

const int _iterations = 30000;

/// PBKDF2-HMAC-SHA256, one 32-byte block.
Uint8List pbkdf2(String key, Uint8List salt, int iterations) {
  final hmac = Hmac(sha256, utf8.encode(key));
  var u = hmac.convert([...salt, 0, 0, 0, 1]).bytes;
  final out = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = hmac.convert(u).bytes;
    for (var j = 0; j < out.length; j++) {
      out[j] ^= u[j];
    }
  }
  return out;
}

String _derive((String, String, int) a) =>
    base64.encode(pbkdf2(a.$1, base64.decode(a.$2), a.$3));

/// Stores only salted hashes of the keys, in the iOS Keychain.
class KeyStore {
  KeyStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  static const _sameFlag = 'vault_same_as_app';

  Future<bool> hasKey(KeySlot slot) async =>
      await _storage.read(key: 'key_${slot.name}') != null;

  Future<void> setKey(KeySlot slot, String key) async {
    final rnd = Random.secure();
    final salt = base64.encode(List<int>.generate(16, (_) => rnd.nextInt(256)));
    final hash = await compute(_derive, (key, salt, _iterations));
    await _storage.write(
      key: 'key_${slot.name}',
      value: '$salt:$_iterations:$hash',
    );
  }

  Future<bool> _check(KeySlot slot, String key) async {
    final stored = await _storage.read(key: 'key_${slot.name}');
    if (stored == null) return false;
    final parts = stored.split(':');
    if (parts.length != 3) return false;
    final hash = await compute(_derive, (key, parts[0], int.parse(parts[1])));
    // Constant-time comparison.
    final a = utf8.encode(hash), b = utf8.encode(parts[2]);
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  /// True when the hidden-video vault opens with the app key.
  Future<bool> vaultUsesAppKey() async =>
      await _storage.read(key: _sameFlag) != 'false';

  /// Pass [vaultKey] to give the vault its own key, or null to share.
  Future<void> setVaultKey(String? vaultKey) async {
    if (vaultKey == null) {
      await _storage.write(key: _sameFlag, value: 'true');
      await _storage.delete(key: 'key_${KeySlot.vault.name}');
    } else {
      await setKey(KeySlot.vault, vaultKey);
      await _storage.write(key: _sameFlag, value: 'false');
    }
  }

  Future<bool> verifyApp(String key) => _check(KeySlot.app, key);

  Future<bool> verifyVault(String key) async => await vaultUsesAppKey()
      ? _check(KeySlot.app, key)
      : _check(KeySlot.vault, key);
}
