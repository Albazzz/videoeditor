import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/app_settings.dart';
import '../services/translator.dart';
import 'common.dart';
import 'picture_picker.dart';

/// Subtitles read from a file, translated to Vietnamese when asked.
class ImportedSubtitles {
  const ImportedSubtitles({
    required this.cues,
    required this.language,
    required this.fileName,
    this.picture,
  });

  /// [Cue.text] is Vietnamese (or the original when not translated),
  /// [Cue.source] the line as written in the file.
  final List<Cue> cues;
  final String language;
  final String fileName;
  final Uint8List? picture;
}

/// Lets the user pick a subtitle file, check its language and translate it.
/// Returns null when cancelled.
Future<ImportedSubtitles?> importSubtitleFile(
  BuildContext context, {
  CapturePicture? capture,
}) async {
  // Any type: iOS greys out .srt/.ass when filtering by extension.
  final picked = await FilePicker.pickFiles(type: FileType.any);
  final path = picked.isEmpty ? null : picked.first.path;
  if (path == null || !context.mounted) return null;

  List<Cue> cues;
  try {
    // Subtitle files are small; a film picked by mistake must not be read
    // into memory.
    if (await File(path).length() > 20 * 1024 * 1024) {
      if (context.mounted) {
        toast(
          context,
          'File quá lớn, không phải file phụ đề (.srt, .vtt, .ass)',
        );
      }
      return null;
    }
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

  final choice = await showModalBottomSheet<(String, bool, Uint8List?)>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) =>
        _ImportSheet(fileName: p.basename(path), cues: cues, capture: capture),
  );
  if (choice == null || !context.mounted) return null;
  final (language, translate, picture) = choice;

  final result = !translate
      ? [
          for (final c in cues)
            Cue(start: c.start, end: c.end, text: c.text, source: c.text),
        ]
      : await translateImportedCues(context, cues, language);
  if (result == null) return null;
  return ImportedSubtitles(
    cues: result,
    language: language,
    fileName: p.basename(path),
    picture: picture,
  );
}

/// Translates a file while keeping successful lines available for retry.
Future<List<Cue>?> translateImportedCues(
  BuildContext context,
  List<Cue> cues,
  String language, {
  Translator? translator,
}) => showDialog<List<Cue>>(
  context: context,
  barrierDismissible: false,
  builder: (_) =>
      _TranslateDialog(cues: cues, language: language, translator: translator),
);

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
  const _ImportSheet({
    required this.fileName,
    required this.cues,
    this.capture,
  });
  final CapturePicture? capture;
  final String fileName;
  final List<Cue> cues;

  @override
  State<_ImportSheet> createState() => _ImportSheetState();
}

class _ImportSheetState extends State<_ImportSheet> {
  Uint8List? _picture;
  bool _pictureBusy = false;
  late String _language = guessLanguage(widget.cues.map((c) => c.text));
  late bool _translate = _language != 'vi';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final preview = widget.cues.take(4).map((c) => c.text).join('\n');
    final canTranslate = Translator.available && _language != 'vi';
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: SingleChildScrollView(
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
              PicturePicker(
                capture: widget.capture,
                onChanged: (v) => _picture = v,
                onBusy: (v) => setState(() => _pictureBusy = v),
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
                  !Translator.available
                      ? 'Máy này không có bộ dịch'
                      : _language == 'vi'
                      ? 'Phụ đề đã là tiếng Việt'
                      : appSettings.useCloud
                      ? 'Dịch qua ${Translator.label}'
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
                  onPressed: _pictureBusy
                      ? null
                      : () => Navigator.pop(context, (
                          _language,
                          canTranslate && _translate,
                          _picture,
                        )),
                  child: const Text('Nhập'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Translates every line with a progress bar. Pops the translated lines,
/// or null when cancelled.
class _TranslateDialog extends StatefulWidget {
  const _TranslateDialog({
    required this.cues,
    required this.language,
    this.translator,
  });
  final List<Cue> cues;
  final String language;
  final Translator? translator;

  @override
  State<_TranslateDialog> createState() => _TranslateDialogState();
}

class _TranslateDialogState extends State<_TranslateDialog> {
  late final _translator = widget.translator ?? Translator.create(force: true);
  String _status = 'Đang chuẩn bị bộ dịch…';
  int _done = 0;
  final _translated = <String, String>{};
  bool _running = false;
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

  late final _flat = [
    for (final c in widget.cues) c.text.replaceAll(RegExp(r'\s*\n\s*'), ' '),
  ];

  void _complete() {
    Navigator.pop(context, [
      for (var i = 0; i < widget.cues.length; i++)
        Cue(
          start: widget.cues[i].start,
          end: widget.cues[i].end,
          text: _translated[_flat[i]] ?? widget.cues[i].text,
          source: widget.cues[i].text,
        ),
    ]);
  }

  Future<void> _run() async {
    if (_running) return;
    setState(() {
      _running = true;
      _error = null;
      _status = 'Đang chuẩn bị bộ dịch…';
    });
    final name = kSubtitleLanguages[widget.language] ?? widget.language;
    final missing = _flat
        .toSet()
        .where((t) => !_translated.containsKey(t))
        .toList();
    try {
      await _translator.prepare(widget.language);
      if (!mounted || _cancelled) return;
      setState(() => _status = 'Đang dịch $name → tiếng Việt');
      final got = await _translator.translateBatch(
        missing,
        widget.language,
        onProgress: (n) {
          if (mounted && !_cancelled) {
            setState(() {
              final count = _translated.length + n;
              _done = (count / _flat.toSet().length * widget.cues.length)
                  .round()
                  .clamp(0, widget.cues.length);
            });
          }
        },
      );
      if (!mounted || _cancelled) return;
      for (var i = 0; i < missing.length && i < got.length; i++) {
        final text = got[i]?.trim();
        if (text != null && text.isNotEmpty) _translated[missing[i]] = text;
      }
      _done = _flat.where(_translated.containsKey).length;
      if (_done < widget.cues.length) {
        setState(
          () => _error =
              '${widget.cues.length - _done} dòng chưa dịch được. '
              'Kiểm tra kết nối rồi thử lại; phần đã dịch vẫn được giữ.',
        );
        return;
      }
      _complete();
    } catch (e) {
      if (mounted && !_cancelled) {
        setState(() {
          _done = _flat.where(_translated.containsKey).length;
          _error = 'Dịch lỗi: $e';
        });
      }
    } finally {
      if (mounted) setState(() => _running = false);
    }
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
            Text('$_done / $total dòng'),
          ],
        ],
      ),
      actions: [
        if (_error != null && !_running) ...[
          TextButton(
            onPressed: _complete,
            child: const Text('Nhập phần đã dịch'),
          ),
          FilledButton.icon(
            onPressed: _run,
            icon: const Icon(Icons.refresh),
            label: const Text('Thử lại'),
          ),
        ],
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
