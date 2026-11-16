import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/openrouter_translator.dart';

/// Chooses between the offline translator and a language model on
/// OpenRouter, with the user's own key.
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

  Future<void> _editKey() async {
    final controller = TextEditingController(text: appSettings.openRouterKey);
    final key = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Key OpenRouter'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Tạo key ở openrouter.ai → Keys, rồi dán vào đây. Key được '
              'cất trong Keychain của iPhone.',
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autocorrect: false,
              enableSuggestions: false,
              obscureText: true,
              decoration: const InputDecoration(
                hintText: 'sk-or-v1-…',
                border: OutlineInputBorder(),
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
    await appSettings.setOpenRouterKey(key);
    setState(() => _testResult = null);
  }

  Future<void> _editCustomModel() async {
    final controller = TextEditingController(text: appSettings.openRouterModel);
    final model = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Model khác'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration: const InputDecoration(
            hintText: 'vd. openai/gpt-5-mini',
            helperText: 'Tên model như trên trang openrouter.ai/models',
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
      appSettings.setOpenRouterModel(model);
    }
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });
    final t = OpenRouterTranslator(
      apiKey: appSettings.openRouterKey,
      model: appSettings.openRouterModel,
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
    final cloud = appSettings.translateEngine == 'openrouter';
    final key = appSettings.openRouterKey;
    final model = appSettings.openRouterModel;
    final preset = kOpenRouterModels.where((m) => m.id == model).firstOrNull;
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
              ],
            ),
          ),
          if (cloud) ...[
            const Divider(),
            ListTile(
              leading: const Icon(Icons.key),
              title: const Text('Key OpenRouter'),
              subtitle: Text(
                key.isEmpty
                    ? 'Chưa có key: chưa dịch bằng OpenRouter được'
                    : 'sk-…${key.substring(key.length - 4)}',
                style: key.isEmpty
                    ? const TextStyle(color: Colors.orange)
                    : null,
              ),
              trailing: const Icon(Icons.edit),
              onTap: _editKey,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text('Model', style: theme.textTheme.titleSmall),
            ),
            RadioGroup<String>(
              groupValue: preset?.id ?? '',
              onChanged: (v) {
                if (v != null) appSettings.setOpenRouterModel(v);
              },
              child: Column(
                children: [
                  for (final m in kOpenRouterModels)
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
              onTap: _editCustomModel,
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  FilledButton.tonalIcon(
                    onPressed: key.isEmpty || _testing ? null : _test,
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
                    'Phim dài được gửi từng đoạn 30 câu, kèm vài câu trước đó '
                    'để giữ mạch và cách xưng hô. Đoạn nào lỗi mạng sẽ tự '
                    'thử lại. Chi tiết từng lần gửi có trong Nhật ký lỗi.',
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
  if (appSettings.translateEngine != 'openrouter') {
    return 'Trên máy (Google ML Kit)';
  }
  if (appSettings.openRouterKey.isEmpty) {
    return 'OpenRouter · chưa có key, đang dùng dịch trên máy';
  }
  final m = kOpenRouterModels
      .where((x) => x.id == appSettings.openRouterModel)
      .firstOrNull;
  return 'OpenRouter · ${m?.name ?? appSettings.openRouterModel}';
}
