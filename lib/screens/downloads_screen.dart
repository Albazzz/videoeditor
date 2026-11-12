import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/model_store.dart';
import '../services/subtitle_store.dart';
import '../services/translator.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';

/// One place that answers "is everything downloaded?": the speech model,
/// each translation pack, and how far every saved subtitle got.
class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});

  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  bool? _speechReady;
  double? _speechProgress;

  /// Pack code -> downloaded, null while unknown.
  final Map<String, bool?> _packs = {
    for (final code in TranslatorPacks.languages.keys) code: null,
  };
  final Set<String> _busy = {};
  String? _packError;

  List<SavedSubs> _web = [];
  int _librarySubs = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final speech = await ModelStore.isReady();
    final web = await SubtitleStore.list();
    var library = 0;
    for (final item in await VideoLibrary.list(hidden: false)) {
      if (item.srtFile.existsSync()) library++;
    }
    if (!mounted) return;
    setState(() {
      _speechReady = speech;
      _web = web;
      _librarySubs = library;
    });
    await _checkPacks();
  }

  Future<void> _checkPacks() async {
    if (!TranslatorPacks.supported || !appSettings.translate) return;
    for (final code in TranslatorPacks.languages.keys) {
      try {
        final have = await TranslatorPacks.isDownloaded(code);
        if (mounted) setState(() => _packs[code] = have);
      } catch (e) {
        if (mounted) setState(() => _packError = '$e');
      }
    }
  }

  Future<void> _downloadSpeech() async {
    setState(() => _speechProgress = 0);
    try {
      await ModelStore.download((v) {
        if (mounted && (v - (_speechProgress ?? 0) > 0.005 || v >= 1)) {
          setState(() => _speechProgress = v);
        }
      });
    } catch (e) {
      if (mounted) toast(context, 'Tải thất bại: $e');
    }
    final ready = await ModelStore.isReady();
    if (mounted) {
      setState(() {
        _speechProgress = null;
        _speechReady = ready;
      });
    }
  }

  Future<void> _deleteSpeech() async {
    await ModelStore.deleteAll();
    final ready = await ModelStore.isReady();
    if (mounted) setState(() => _speechReady = ready);
  }

  Future<void> _pack(String code, {required bool download}) async {
    setState(() {
      _busy.add(code);
      _packError = null;
    });
    try {
      if (download) {
        await TranslatorPacks.download(code);
      } else {
        await TranslatorPacks.delete(code);
      }
      final have = await TranslatorPacks.isDownloaded(code);
      if (mounted) setState(() => _packs[code] = have);
    } catch (e) {
      if (mounted) setState(() => _packError = '$e');
    }
    if (mounted) setState(() => _busy.remove(code));
  }

  /// Whether the language picked in Settings can be translated right now.
  String _readiness() {
    final lang = appSettings.language;
    final name = kLanguages[lang] ?? lang;
    if (!appSettings.translate) return 'Đang tắt dịch: phụ đề hiện tiếng gốc';
    if (!TranslatorPacks.supported) return 'Máy này không có bộ dịch';
    if (lang == 'auto') return 'Tự nhận diện: cần gói của tiếng được nói';
    final need = ['vi', TranslatorPacks.codeFor(lang)];
    if (need.any((c) => _packs[c] == null)) return 'Đang kiểm tra…';
    final missing = need.where((c) => _packs[c] == false).toList();
    if (missing.isEmpty) return '$name → Việt: sẵn sàng, dịch không cần mạng';
    return '$name → Việt: còn thiếu gói '
        '${missing.map((c) => TranslatorPacks.languages[c]).join(', ')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mb = (ModelStore.totalBytes / 1e6).round();
    final complete = _web.where((s) => s.isWholeVideo).length;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tình trạng tải về'),
        actions: [
          IconButton(
            tooltip: 'Kiểm tra lại',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
        ],
      ),
      body: ListView(
        children: [
          const _Header('Nhận dạng giọng nói'),
          ListTile(
            leading: _StatusIcon(ready: _speechReady),
            title: const Text('Bộ nhận dạng Nhật/Trung/Hàn/Anh'),
            subtitle: _speechProgress != null
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Đang tải ${(_speechProgress! * 100).toStringAsFixed(0)}%',
                      ),
                      const SizedBox(height: 6),
                      LinearProgressIndicator(value: _speechProgress),
                    ],
                  )
                : Text(
                    _speechReady == null
                        ? 'Đang kiểm tra…'
                        : _speechReady!
                        ? 'Đã tải xong ($mb MB)'
                        : 'Chưa tải ($mb MB)',
                  ),
            trailing: _speechProgress != null || _speechReady == null
                ? null
                : _speechReady!
                ? TextButton(onPressed: _deleteSpeech, child: const Text('Xoá'))
                : FilledButton.tonal(
                    onPressed: _downloadSpeech,
                    child: const Text('Tải'),
                  ),
          ),
          const _Header('Bộ dịch sang tiếng Việt'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(_readiness(), style: theme.textTheme.bodyMedium),
          ),
          if (TranslatorPacks.supported && appSettings.translate)
            for (final e in TranslatorPacks.languages.entries)
              ListTile(
                leading: _busy.contains(e.key)
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _StatusIcon(ready: _packs[e.key]),
                title: Text(e.value),
                subtitle: Text(
                  _busy.contains(e.key)
                      ? 'Đang xử lý… (khoảng 30 MB)'
                      : switch (_packs[e.key]) {
                          null => 'Đang kiểm tra…',
                          true => 'Đã tải xong',
                          false => 'Chưa tải (khoảng 30 MB)',
                        },
                ),
                trailing: _busy.contains(e.key) || _packs[e.key] == null
                    ? null
                    : _packs[e.key]!
                    ? TextButton(
                        onPressed: () => _pack(e.key, download: false),
                        child: const Text('Xoá'),
                      )
                    : FilledButton.tonal(
                        onPressed: () => _pack(e.key, download: true),
                        child: const Text('Tải'),
                      ),
              ),
          if (_packError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                'Lỗi bộ dịch: $_packError',
                style: TextStyle(color: theme.colorScheme.error),
              ),
            ),
          const _Header('Phụ đề đã làm'),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text('${_web.length} phim từ web'),
            subtitle: Text(
              '$complete phim đủ cả phim, '
              '${_web.length - complete} phim mới làm một phần',
            ),
          ),
          ListTile(
            leading: const Icon(Icons.movie_outlined),
            title: Text('$_librarySubs video trong Thư viện có phụ đề'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            child: Text(
              'Xem từng phim và phần trăm đã làm ở tab Phụ đề.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon({required this.ready});
  final bool? ready;

  @override
  Widget build(BuildContext context) => switch (ready) {
    null => const Icon(Icons.hourglass_empty),
    true => const Icon(Icons.check_circle, color: Colors.green),
    false => Icon(
      Icons.cloud_download_outlined,
      color: Theme.of(context).colorScheme.outline,
    ),
  };
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
