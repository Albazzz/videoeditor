import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/openrouter_translator.dart';

/// Chooses between the offline translator and a language model on an AI
/// service (OpenRouter, Vercel AI Gateway), with the user's own key.
class TranslationSettingsScreen extends StatefulWidget {
  const TranslationSettingsScreen({super.key});

  @override
  State<TranslationSettingsScreen> createState() =>
      _TranslationSettingsScreenState();
}

class _TranslationSettingsScreenState extends State<TranslationSettingsScreen> {
  String? _testResult;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    appSettings.addListener(_refresh);
  }

  @override
  void dispose() {
    appSettings.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _editKey(AiProvider provider) async {
    final controller = TextEditingController(
      text: appSettings.keyFor(provider),
    );
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Key ${provider.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${provider.keyHelp}, rồi dán vào đây. Key được cất trong '
              'Keychain của iPhone.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              decoration: InputDecoration(
                hintText: provider.keyHint,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, ''),
            child: const Text('Xoá key'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Lưu'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (key == null) return;
    await appSettings.setKey(provider, key);
    setState(() => _testResult = null);
  }

  Future<void> _editCustomModel(AiProvider provider) async {
    final controller = TextEditingController(
      text: appSettings.modelFor(provider),
    );
    final model = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model khác'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'vd. openai/gpt-5-mini',
            helperText: 'Tên model đúng như trang danh sách model',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Dùng'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (model != null && model.isNotEmpty) {
      appSettings.setModel(provider, model);
    }
  }

  Future<void> _test(AiProvider provider) async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final t = OpenRouterTranslator(
      provider: provider,
      apiKey: appSettings.keyFor(provider),
      model: appSettings.modelFor(provider),
      retryDelay: const Duration(milliseconds: 500),
    );
    try {
      final out = await t.translateBatch([
        'お前、まだ起きてたのか？',
        '你别管我，我自己能行。',
      ], 'auto');
      _testResult =
          'Dịch thử:\n${out.map((l) => '• ${l ?? '(trống)'}').join('\n')}';
    } catch (e) {
      _testResult = 'Lỗi: $e';
    } finally {
      await t.dispose();
    }
    if (mounted) setState(() => _testing = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final provider = appSettings.aiProvider;
    final key = provider == null ? '' : appSettings.keyFor(provider);
    final model = provider == null ? '' : appSettings.modelFor(provider);
    final preset = provider?.models.where((m) => m.id == model).firstOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Cách dịch')),
      body: ListView(
        children: [
          RadioGroup<String>(
            groupValue: appSettings.translateEngine,
            onChanged: (v) {
              if (v != null) appSettings.setTranslateEngine(v);
            },
            child: const Column(
              children: [
                RadioListTile(
                  value: 'device',
                  title: Text('Trên máy (Google ML Kit)'),
                  subtitle: Text('Miễn phí, không cần mạng, dịch khá cứng'),
                ),
                RadioListTile(
                  value: 'openrouter',
                  title: Text('OpenRouter (AI)'),
                  subtitle: Text(
                    'Dịch tự nhiên, hiểu ngữ cảnh. Cần key và mạng, '
                    'tốn rất ít tiền hoặc dùng model miễn phí',
                  ),
                ),
                RadioListTile(
                  value: 'vercel',
                  title: Text('Vercel AI Gateway (AI)'),
                  subtitle: Text(
                    'Cùng các model như OpenRouter, trả tiền qua Vercel. '
                    'Cần key AI Gateway và mạng',
                  ),
                ),
              ],
            ),
          ),
          if (provider != null) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.key),
              title: Text('Key ${provider.name}'),
              subtitle: Text(
                key.isEmpty
                    ? 'Chưa có key: chưa dịch bằng ${provider.name} được'
                    : '…${key.substring(key.length < 4 ? 0 : key.length - 4)}',
                style: key.isEmpty
                    ? const TextStyle(color: Colors.orange)
                    : null,
              ),
              trailing: const Icon(Icons.edit),
              onTap: () => _editKey(provider),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Model', style: theme.textTheme.titleSmall),
            ),
            RadioGroup<String>(
              groupValue: preset?.id ?? '',
              onChanged: (v) {
                if (v != null) appSettings.setModel(provider, v);
              },
              child: Column(
                children: [
                  for (final m in provider.models)
                    RadioListTile(
                      value: m.id,
                      title: Text(m.name),
                      subtitle: Text(m.note),
                    ),
                ],
              ),
            ),
            ListTile(
              leading: Icon(
                preset == null
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                color: preset == null ? theme.colorScheme.primary : null,
              ),
              title: const Text('Model khác…'),
              subtitle: Text(preset == null ? model : 'Gõ tên model bất kỳ'),
              onTap: () => _editCustomModel(provider),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: key.isEmpty || _testing
                        ? null
                        : () => _test(provider),
                    icon: _testing
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.translate),
                    label: const Text('Dịch thử'),
                  ),
                  if (_testResult != null) ...[
                    const SizedBox(height: 8),
                    SelectableText(_testResult!),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Câu được gom thành từng đoạn khoảng 1.500 chữ (không cắt '
                    'ngang câu), gửi 3 đoạn cùng lúc, kèm vài câu trước đó để '
                    'giữ mạch và cách xưng hô. Đoạn lỗi mạng tự thử lại; hết '
                    'tiền hoặc sai key thì tự chuyển sang dịch trên máy. Chi '
                    'tiết từng lần gửi có trong Nhật ký lỗi.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// One-line summary for the Settings list.
String translationSummary() {
  final p = appSettings.aiProvider;
  if (p == null) return 'Trên máy (Google ML Kit)';
  if (appSettings.keyFor(p).isEmpty) {
    return '${p.name} · chưa có key, đang dùng dịch trên máy';
  }
  final id = appSettings.modelFor(p);
  final m = p.models.where((x) => x.id == id).firstOrNull;
  return '${p.name} · ${m?.name ?? id}';
}
