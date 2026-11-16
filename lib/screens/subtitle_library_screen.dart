import 'package:flutter/material.dart';

import '../services/active_work.dart';
import '../widgets/activity_icon.dart';
import '../widgets/session_progress.dart';

import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/app_settings.dart';
import '../services/subtitle_store.dart';
import '../services/translator.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';
import 'downloads_screen.dart';
import '../widgets/subtitle_details.dart';

/// Every subtitle the app has made: for web videos and for library videos.
/// Hidden videos are left out on purpose.
class SubtitleLibraryScreen extends StatefulWidget {
  const SubtitleLibraryScreen({super.key});

  @override
  State<SubtitleLibraryScreen> createState() => _SubtitleLibraryScreenState();
}

class _SubtitleLibraryScreenState extends State<SubtitleLibraryScreen> {
  List<SavedSubs>? _web;
  List<(VideoItem, List<Cue>)> _videos = [];
  int _bytes = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final web = await SubtitleStore.list();
    final bytes = await SubtitleStore.storageBytes();
    final videos = <(VideoItem, List<Cue>)>[];
    for (final item in await VideoLibrary.list(hidden: false)) {
      if (!item.srtFile.existsSync()) continue;
      videos.add((item, await VideoLibrary.loadCues(item)));
    }
    if (!mounted) return;
    setState(() {
      _web = web;
      _videos = videos;
      _bytes = bytes;
    });
  }

  String _date(DateTime d) =>
      '${d.day}/${d.month}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  String _label(SavedSubs s) => s.imported
      ? 'Từ file · ${kSubtitleLanguages[s.language] ?? s.language} → Việt'
      : subtitleProgressLabel(
          covered: s.covered,
          duration: s.duration,
          reachedEnd: s.complete,
        );

  static String _size(int bytes) => bytes < 1024 * 1024
      ? '${(bytes / 1024).toStringAsFixed(0)} KB'
      : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';

  String _host(String page) => Uri.tryParse(page)?.host ?? page;

  Future<void> _open({
    required String title,
    required String subtitle,
    required List<Cue> cues,
    required Future<void> Function() onDelete,
    SavedSubs? saved,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SubtitleView(
          title: title,
          subtitle: subtitle,
          cues: cues,
          saved: saved,
          onDelete: onDelete,
        ),
      ),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Kho phụ đề'),
            if (web != null && web.isNotEmpty)
              Text(
                '${web.length} trang · ${_size(_bytes)}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: 'Tình trạng tải về',
            icon: const Icon(Icons.download_done),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const DownloadsScreen()),
            ),
          ),
        ],
      ),
      body: web == null
          ? const Center(child: CircularProgressIndicator())
          : web.isEmpty && _videos.isEmpty && ActiveWork.current.value == null
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'Chưa có phụ đề nào.\n'
                  'Phụ đề tạo khi xem web hoặc xem video trong Thư viện '
                  'sẽ được lưu ở đây.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                children: [
                  const _ActiveCard(),
                  if (web.isNotEmpty) const _Section('Từ web'),
                  for (final s in web)
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: Text(
                        s.title.isEmpty ? _host(s.page) : s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _label(s),
                            style: TextStyle(
                              color: s.isWholeVideo
                                  ? Colors.green
                                  : Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (s.progress != null) ...[
                            const SizedBox(height: 4),
                            LinearProgressIndicator(
                              value: s.progress,
                              minHeight: 3,
                              color: s.isWholeVideo ? Colors.green : null,
                            ),
                            const SizedBox(height: 4),
                          ],
                          Text(
                            '${s.cues.length} dòng · '
                            '${kLanguages[s.language] ?? s.language} · '
                            '${_date(s.updated)}',
                          ),
                        ],
                      ),
                      isThreeLine: true,
                      onTap: () => _open(
                        title: s.title.isEmpty ? _host(s.page) : s.title,
                        subtitle:
                            '${_label(s)}'
                            '\n${s.page}',
                        cues: s.cues,
                        saved: s,
                        onDelete: () => SubtitleStore.delete(s.id),
                      ),
                    ),
                  if (_videos.isNotEmpty)
                    const _Section('Video trong Thư viện'),
                  for (final (item, cues) in _videos)
                    ListTile(
                      leading: const Icon(Icons.movie_outlined),
                      title: Text(
                        item.name,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text('Đủ cả video · ${cues.length} dòng'),
                      onTap: () => _open(
                        title: item.name,
                        subtitle: 'Video trong Thư viện',
                        cues: cues,
                        onDelete: () => item.srtFile.delete(),
                      ),
                    ),
                ],
              ),
            ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
    child: Text(
      text,
      style: TextStyle(
        color: Theme.of(context).colorScheme.primary,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _SubtitleView extends StatefulWidget {
  const _SubtitleView({
    required this.title,
    required this.subtitle,
    required this.cues,
    required this.onDelete,
    this.saved,
  });

  final String title;
  final String subtitle;
  final List<Cue> cues;
  final Future<void> Function() onDelete;

  /// Web entries can be renamed, translated again and edited.
  final SavedSubs? saved;

  @override
  State<_SubtitleView> createState() => _SubtitleViewState();
}

class _SubtitleViewState extends State<_SubtitleView> {
  late String title = widget.title;
  late List<Cue> cues = widget.cues;
  late SavedSubs? saved = widget.saved;
  String get subtitle => widget.subtitle;
  Future<void> Function() get onDelete => widget.onDelete;

  Future<void> _store(SavedSubs next) async {
    await SubtitleStore.save(next);
    if (!mounted) return;
    setState(() {
      saved = next;
      title = next.title.isEmpty ? title : next.title;
      cues = next.cues;
    });
  }

  Future<String?> _ask(String heading, String initial, {int lines = 1}) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(heading),
        content: TextField(
          controller: c,
          autofocus: true,
          minLines: lines,
          maxLines: lines + 2,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, c.text.trim()),
            child: const Text('Lưu'),
          ),
        ],
      ),
    ).whenComplete(c.dispose);
  }

  Future<void> _rename() async {
    final s = saved;
    if (s == null) return;
    final name = await _ask('Đổi tên', title);
    if (name == null || name.isEmpty) return;
    await _store(s.withTitle(name));
  }

  Future<void> _editLine(int i) async {
    final s = saved;
    if (s == null) return;
    final c = cues[i];
    final text = await _ask(
      'Sửa dòng ${formatTime(c.start)}'
      '${c.source.isNotEmpty && c.source != c.text ? '\n${c.source}' : ''}',
      c.text,
      lines: 2,
    );
    if (text == null || text.isEmpty || text == c.text) return;
    final next = List.of(cues)
      ..[i] = Cue(start: c.start, end: c.end, text: text, source: c.source);
    await _store(s.withCues(next));
  }

  /// Translates the lines still in the original language.
  Future<void> _retranslate() async {
    final s = saved;
    if (s == null) return;
    final todo = [
      for (var i = 0; i < cues.length; i++)
        if (cues[i].source.isNotEmpty && cues[i].text == cues[i].source) i,
    ];
    if (todo.isEmpty) return;
    final translator = Translator.create(force: true);
    final done = ValueNotifier(0);
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Dịch lại'),
        content: ValueListenableBuilder(
          valueListenable: done,
          builder: (context, n, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${Translator.label}\n$n / ${todo.length} câu'),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: n / todo.length),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              cancelled = true;
              Navigator.pop(context);
            },
            child: const Text('Huỷ'),
          ),
        ],
      ),
    );
    try {
      await translator.prepare(s.language);
      final out = await translator.translateBatch(
        [for (final i in todo) cues[i].source],
        s.language,
        onProgress: (n) => done.value = n,
      );
      if (cancelled || !mounted) return;
      Navigator.pop(context);
      final next = List.of(cues);
      var got = 0;
      for (var k = 0; k < todo.length; k++) {
        final t = out[k];
        if (t == null || t.isEmpty) continue;
        final c = next[todo[k]];
        next[todo[k]] = Cue(
          start: c.start,
          end: c.end,
          text: t,
          source: c.source,
        );
        got++;
      }
      await _store(s.withCues(next));
      if (mounted) {
        toast(
          context,
          got == todo.length
              ? 'Đã dịch $got câu'
              : 'Đã dịch $got/${todo.length} câu, bấm lại để thử tiếp',
        );
      }
    } catch (e) {
      if (!cancelled && mounted) {
        Navigator.pop(context);
        toast(context, 'Dịch lỗi: $e');
      }
    } finally {
      await translator.dispose();
      done.dispose();
    }
  }

  Future<void> _export(BuildContext context) async {
    try {
      final name = await SubtitleStore.exportSrt(title, cues);
      if (context.mounted) {
        toast(context, 'Đã lưu $name, xem trong app Tệp > Video Sub');
      }
    } catch (e) {
      if (context.mounted) toast(context, 'Không lưu được: $e');
    }
  }

  Future<void> _delete(BuildContext context) async {
    final ok =
        await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Xoá phụ đề?'),
            content: Text('Xoá phụ đề của "$title". Video không bị ảnh hưởng.'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Huỷ'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Xoá'),
              ),
            ],
          ),
        ) ==
        true;
    if (!ok) return;
    await onDelete();
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: GestureDetector(
          onTap: saved == null ? null : _rename,
          child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
        actions: [
          if (saved != null)
            IconButton(
              tooltip: 'Đổi tên',
              icon: const Icon(Icons.drive_file_rename_outline),
              onPressed: _rename,
            ),
          IconButton(
            tooltip: 'Lưu file .srt',
            icon: const Icon(Icons.download_outlined),
            onPressed: cues.isEmpty ? null : () => _export(context),
          ),
          IconButton(
            tooltip: 'Xoá',
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _delete(context),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              '$subtitle\n${cues.length} dòng',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          if ((saved?.untranslated ?? 0) > 0)
            MaterialBanner(
              content: Text(
                '${saved!.untranslated} câu chưa dịch (lỗi hoặc quá lâu lúc '
                'làm). Dịch lại bằng ${Translator.label}?',
              ),
              actions: [
                TextButton(
                  onPressed: _retranslate,
                  child: const Text('Dịch lại'),
                ),
              ],
            ),
          if (saved != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                'Chạm vào một dòng để sửa',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: CueList(cues: cues, onTap: saved == null ? null : _editLine),
          ),
        ],
      ),
    );
  }
}

/// The subtitles being made right now, with their live progress.
class _ActiveCard extends StatelessWidget {
  const _ActiveCard();

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: ActiveWork.current,
      builder: (context, work, _) {
        if (work == null) return const SizedBox.shrink();
        final s = work.session;
        return ListenableBuilder(
          listenable: s,
          builder: (context, _) => Card(
            margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => showSessionProgress(context, s, title: work.title),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ActivityIcon(session: s, title: work.title),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Đang làm: ${work.title}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                        const Icon(Icons.chevron_right),
                      ],
                    ),
                    const SizedBox(height: 6),
                    if (s.duration > 0)
                      CoverageBar(
                        covered: s.covered,
                        duration: s.duration,
                        done: coversWholeVideo(
                          s.covered,
                          s.duration,
                          reachedEnd: s.reachedEnd,
                        ),
                      ),
                    Text(
                      '${s.stage} · ${s.cues.length} dòng',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    Text(
                      'Chạm để xem từng bước',
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
