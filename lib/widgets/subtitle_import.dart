import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/translator.dart';
import 'common.dart';

/// Subtitles read from a file, translated to Vietnamese when asked.
class ImportedSubtitles {
  const ImportedSubtitles({
    required this.cues,
    required this.language,
    required this.fileName,
  });

  /// [Cue.text] is Vietnamese (or the original when not translated),
  /// [Cue.source] the line as written in the file.
  final List<Cue> cues;
  final String language;
  final String fileName;
}

/// Lets the user pick a subtitle file, check its language and translate it.
/// Returns null when cancelled.
Future<ImportedSubtitles?> importSubtitleFile(BuildContext context) async {
  // Any type: iOS greys out .srt/.ass when filtering by extension.
  final picked = await FilePicker.pickFiles(type: FileType.any);
  final path = picked.isEmpty ? null : picked.first.path;
  if (path == null || !context.mounted) return null;

  List<Cue> cues;
  try {
    final text = decodeSubtitleBytes(await File(path).readAsBytes());
    cues = parseSubtitleFile(text);
  } catch (e) {
    if (context.mounted) toast(context, 'Không đọc được file: $e');
    return null;
  }
  if (!context.mounted) return null;
  if (cues.isEmpty) {
    toast(
      context,
      'File này không có dòng phụ đề nào (cần .srt, .vtt hoặc .ass)',
    );
    return null;
  }

  final choice = await showModalBottomSheet<(String, bool)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ImportSheet(fileName: p.basename(path), cues: cues),
  );
  if (choice == null || !context.mounted) return null;
  final (language, translate) = choice;

  final result = !translate
      ? [
          for (final c in cues)
            Cue(start: c.start, end: c.end, text: c.text, source: c.text),
        ]
      : await showDialog<List<Cue>>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _TranslateDialog(cues: cues, language: language),
        );
  if (result == null) return null;
  return ImportedSubtitles(
    cues: result,
    language: language,
    fileName: p.basename(path),
  );
}

/// Shifts every line by [seconds]; negative shows them earlier.
List<Cue> shiftCues(List<Cue> cues, double seconds) => [
  for (final c in cues)
    if (c.end + seconds > 0)
      Cue(
        start: (c.start + seconds).clamp(0, double.infinity).toDouble(),
        end: c.end + seconds,
        text: c.text,
        source: c.source,
      ),
];

class _ImportSheet extends StatefulWidget {
  const _ImportSheet({required this.fileName, required this.cues});
  final String fileName;
  final List<Cue> cues;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  late String _language = guessLanguage(widget.cues.map((c) => c.text));
  late bool _translate = _language != 'vi';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.cues.take(4).map((c) => c.text).join('\n');
    final canTranslate = TranslatorPacks.supported && _language != 'vi';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Nhập phụ đề', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              '${widget.fileName} · ${widget.cues.length} dòng · '
              'dài ${formatTime(widget.cues.last.end)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                preview,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Text('Phụ đề đang là: '),
                const SizedBox(width: 8),
                Expanded(
                  child: DropdownButton<String>(
                    isExpanded: true,
                    value: _language,
                    items: [
                      for (final e in kSubtitleLanguages.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() {
                      _language = v!;
                      _translate = v != 'vi';
                    }),
                  ),
                ),
              ],
            ),
            Text(
              'App đoán ngôn ngữ từ nội dung, sai thì chọn lại.',
              style: theme.textTheme.bodySmall,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Dịch sang tiếng Việt'),
              subtitle: Text(
                !TranslatorPacks.supported
                    ? 'Máy này không có bộ dịch'
                    : _language == 'vi'
                    ? 'Phụ đề đã là tiếng Việt'
                    : 'Dịch ngay trên máy, lần đầu tải gói dịch ~30 MB',
              ),
              value: canTranslate && _translate,
              onChanged: canTranslate
                  ? (v) => setState(() => _translate = v)
                  : null,
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: () => Navigator.pop(context, (
                  _language,
                  canTranslate && _translate,
                )),
                child: const Text('Nhập'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Translates every line with a progress bar. Pops the translated lines,
/// or null when cancelled.
class _TranslateDialog extends StatefulWidget {
  const _TranslateDialog({required this.cues, required this.language});
  final List<Cue> cues;
  final String language;

  @override
  State<_TranslateDialog> createState() => _TranslateDialogState();
}

class _TranslateDialogState extends State<_TranslateDialog> {
  final _translator = MlKitTranslator();
  String _status = 'Đang chuẩn bị gói dịch…';
  int _done = 0;
  int _failed = 0;
  bool _cancelled = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  @override
  void dispose() {
    _translator.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final name = kSubtitleLanguages[widget.language] ?? widget.language;
    try {
      setState(
        () => _status =
            'Đang tải gói dịch $name và tiếng Việt '
            '(lần đầu khoảng 30 MB mỗi gói)…',
      );
      await _translator.prepare(widget.language);
    } catch (e) {
      if (mounted) setState(() => _error = 'Không tải được gói dịch: $e');
      return;
    }
    if (!mounted || _cancelled) return;
    setState(() => _status = 'Đang dịch $name → tiếng Việt');

    final out = List<Cue?>.filled(widget.cues.length, null);
    // Repeated lines ("Hả?", "Cảm ơn") are translated once.
    final cache = <String, Future<String>>{};
    Future<void> one(int i) async {
      final c = widget.cues[i];
      final flat = c.text.replaceAll('\n', ' ');
      String text;
      try {
        text = await cache.putIfAbsent(
          flat,
          () => _translator.translate(flat, widget.language),
        );
      } catch (_) {
        text = c.text;
        _failed++;
      }
      out[i] = Cue(start: c.start, end: c.end, text: text, source: c.text);
      _done++;
    }

    const batch = 4;
    for (var i = 0; i < widget.cues.length; i += batch) {
      if (_cancelled || !mounted) return;
      final end = (i + batch).clamp(0, widget.cues.length);
      await Future.wait([for (var j = i; j < end; j++) one(j)]);
      if (mounted) setState(() {});
    }
    if (mounted) Navigator.pop(context, out.cast<Cue>());
  }

  @override
  Widget build(BuildContext context) {
    final total = widget.cues.length;
    return AlertDialog(
      title: const Text('Dịch phụ đề'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_error ?? _status),
          if (_error == null) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _done == 0 ? null : _done / total),
            const SizedBox(height: 8),
            Text(
              '$_done / $total dòng'
              '${_failed > 0 ? ' · $_failed dòng giữ nguyên do lỗi' : ''}',
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            _cancelled = true;
            Navigator.pop(context);
          },
          child: Text(_error == null ? 'Huỷ' : 'Đóng'),
        ),
      ],
    );
  }
}
