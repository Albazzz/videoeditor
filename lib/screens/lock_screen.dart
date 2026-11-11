import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// First launch: create the keys. Afterwards: ask for the app key.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.setup, required this.onUnlocked});

  final bool setup;
  final VoidCallback onUnlocked;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final _key = TextEditingController();
  final _confirm = TextEditingController();
  final _vault = TextEditingController();
  bool _sameKey = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _key.dispose();
    _confirm.dispose();
    _vault.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final key = _key.text;
    String? error;
    if (widget.setup) {
      if (key.length < 4) {
        error = 'Key cần ít nhất 4 ký tự';
      } else if (key != _confirm.text) {
        error = 'Hai lần nhập không khớp';
      } else if (!_sameKey && _vault.text.length < 4) {
        error = 'Key kho ẩn cần ít nhất 4 ký tự';
      }
    }
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    if (widget.setup) {
      await keyStore.setKey(KeySlot.app, key);
      await keyStore.setVaultKey(_sameKey ? null : _vault.text);
      widget.onUnlocked();
    } else if (await keyStore.verifyApp(key)) {
      widget.onUnlocked();
    } else if (mounted) {
      _key.clear();
      setState(() {
        _busy = false;
        _error = 'Sai key';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final setup = widget.setup;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 56,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    setup ? 'Tạo key mở app' : 'Nhập key để mở app',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _key,
                    autofocus: true,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Key mở app',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => setup ? null : _submit(),
                  ),
                  if (setup) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _confirm,
                      obscureText: true,
                      decoration: const InputDecoration(
                        labelText: 'Nhập lại key',
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Kho video ẩn dùng chung key này'),
                      subtitle: const Text('Tắt để đặt key riêng cho kho ẩn'),
                      value: _sameKey,
                      onChanged: (v) => setState(() => _sameKey = v),
                    ),
                    if (!_sameKey)
                      TextField(
                        controller: _vault,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Key kho ẩn',
                          border: OutlineInputBorder(),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Text(
                      'Hãy nhớ key: không có cách lấy lại nếu quên.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: _busy ? null : _submit,
                    child: _busy
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(setup ? 'Lưu và vào app' : 'Mở khoá'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
