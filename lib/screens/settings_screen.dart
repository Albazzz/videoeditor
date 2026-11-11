import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/model_store.dart';
import '../widgets/common.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _vaultShared = true;
  bool _modelsReady = false;

  @override
  void initState() {
    super.initState();
    appSettings.addListener(_refresh);
    _load();
  }

  @override
  void dispose() {
    appSettings.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    final shared = await keyStore.vaultUsesAppKey();
    final ready = await ModelStore.isReady();
    if (mounted) {
      setState(() {
        _vaultShared = shared;
        _modelsReady = ready;
      });
    }
  }

  /// Asks twice for a new key. Returns null when cancelled or mismatched.
  Future<String?> _newKey(String what) async {
    final first = await askKey(context, 'Key mới cho $what', label: 'Key mới');
    if (first == null || !mounted) return null;
    if (first.length < 4) {
      toast(context, 'Key cần ít nhất 4 ký tự');
      return null;
    }
    final second = await askKey(context, 'Nhập lại key mới', label: 'Key mới');
    if (second == null || !mounted) return null;
    if (first != second) {
      toast(context, 'Hai lần nhập không khớp');
      return null;
    }
    return first;
  }

  Future<void> _changeAppKey() async {
    final current = await askKey(context, 'Nhập key mở app hiện tại');
    if (current == null || !mounted) return;
    if (!await keyStore.verifyApp(current)) {
      if (mounted) toast(context, 'Sai key');
      return;
    }
    if (!mounted) return;
    final key = await _newKey('app');
    if (key == null) return;
    await keyStore.setKey(KeySlot.app, key);
    if (mounted) toast(context, 'Đã đổi key mở app');
  }

  Future<bool> _checkVault() async {
    final current = await askKey(context, 'Nhập key kho ẩn hiện tại');
    if (current == null || !mounted) return false;
    if (await keyStore.verifyVault(current)) return true;
    if (mounted) toast(context, 'Sai key');
    return false;
  }

  Future<void> _setVaultShared(bool shared) async {
    if (!await _checkVault() || !mounted) return;
    if (shared) {
      await keyStore.setVaultKey(null);
    } else {
      final key = await _newKey('kho ẩn');
      if (key == null) return;
      await keyStore.setVaultKey(key);
    }
    await _load();
    if (mounted) {
      toast(
        context,
        shared ? 'Kho ẩn giờ dùng key mở app' : 'Đã đặt key riêng cho kho ẩn',
      );
    }
  }

  Future<void> _changeVaultKey() async {
    if (!await _checkVault() || !mounted) return;
    final key = await _newKey('kho ẩn');
    if (key == null) return;
    await keyStore.setVaultKey(key);
    if (mounted) toast(context, 'Đã đổi key kho ẩn');
  }

  @override
  Widget build(BuildContext context) {
    final mb = (ModelStore.totalBytes / 1e6).round();
    return Scaffold(
      appBar: AppBar(title: const Text('Cài đặt')),
      body: ListView(
        children: [
          const _Header('Phụ đề'),
          ListTile(
            title: const Text('Ngôn ngữ trong video'),
            subtitle: const Text('Phụ đề luôn được dịch sang tiếng Việt'),
            trailing: DropdownButton<String>(
              value: appSettings.language,
              underline: const SizedBox.shrink(),
              items: [
                for (final e in kLanguages.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => appSettings.setLanguage(v!),
            ),
          ),
          SwitchListTile(
            title: const Text('Hiện cả câu gốc'),
            subtitle: const Text(
              'Câu tiếng Nhật/Trung nằm trên câu tiếng Việt',
            ),
            value: appSettings.showSource,
            onChanged: appSettings.setShowSource,
          ),
          ListTile(
            title: const Text('Bộ nhận dạng giọng nói'),
            subtitle: Text(
              _modelsReady
                  ? 'Đã tải ($mb MB), chạy không cần mạng'
                  : 'Chưa tải ($mb MB)',
            ),
            trailing: _modelsReady
                ? TextButton(
                    onPressed: () async {
                      await ModelStore.deleteAll();
                      await _load();
                    },
                    child: const Text('Xoá'),
                  )
                : FilledButton.tonal(
                    onPressed: () async {
                      await ensureModels(context);
                      await _load();
                    },
                    child: const Text('Tải'),
                  ),
          ),
          const _Header('Khoá'),
          ListTile(
            leading: const Icon(Icons.key_outlined),
            title: const Text('Đổi key mở app'),
            onTap: _changeAppKey,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.lock_outline),
            title: const Text('Kho ẩn dùng chung key mở app'),
            subtitle: const Text('Tắt để kho ẩn có key riêng'),
            value: _vaultShared,
            onChanged: _setVaultShared,
          ),
          if (!_vaultShared)
            ListTile(
              leading: const Icon(Icons.password),
              title: const Text('Đổi key kho ẩn'),
              onTap: _changeVaultKey,
            ),
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'App tự khoá mỗi khi bạn thoát ra màn hình chính. '
              'Quên key thì không lấy lại được.',
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}
