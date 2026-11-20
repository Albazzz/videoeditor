import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/active_work.dart';
import '../services/open_page.dart';
import '../widgets/activity_icon.dart';

import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/app_settings.dart';
import '../services/bookmarks.dart';
import '../services/subtitle_store.dart';
import '../services/translator.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';
import 'downloads_screen.dart';
import 'retained_audio_screen.dart';
import '../widgets/subtitle_details.dart';
import '../widgets/subtitle_revision.dart';
import '../widgets/video_language.dart';

/// "Làm lại từ đầu": after asking, stops any work on [s], deletes its
/// lines and opens the page to make them again from the start of the
/// film. True when it went ahead.
Future<bool> restartSubtitles(BuildContext context, SavedSubs s) async {
  final name = s.title.isEmpty ? (Uri.tryParse(s.page)?.host ?? '') : s.title;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Làm lại từ đầu?'),
      content: Text(
        'Xoá ${s.cues.length} dòng phụ đề của "$name" rồi nghe và dịch lại '
        'từ đầu khi phim chạy trên trang.\n\n'
        'Chỉ muốn dịch lại câu sai thì dùng "Dịch lại"; còn thiếu đoạn thì '
        'dùng "Làm tiếp".',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Làm lại'),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  await ActiveWork.stop(ActiveWork.find(s.id)?.session);
  await SubtitleStore.delete(s.id);
  ActiveWork.forgetStopped(s.id);
  requestRestart(s.page);
  if (context.mounted) {
    toast(context, 'Mở trang, sẽ làm lại từ đầu khi phim chạy');
  }
  return true;
}

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
  String? _thumbs;

  @override
  void initState() {
    super.initState();
    _reload();
    Bookmarks.thumbDir().then((dir) {
      if (mounted && dir != null) setState(() => _thumbs = dir.path);
    });
  }

  /// The page's picture (taken when it was saved or its subtitles began).
  Widget _picture(SavedSubs s) {
    final dir = _thumbs;
    final file = dir == null || !s.page.startsWith('http')
        ? null
        : File(p.join(dir, Bookmarks.thumbName(s.page)));
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 64,
        height: 40,
        child: file != null && file.existsSync()
            ? Image.file(file, fit: BoxFit.cover, cacheWidth: 192)
            : ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.primary.withValues(alpha: 0.12),
                child: Icon(
                  s.page.startsWith('http')
                      ? Icons.closed_caption
                      : Icons.subtitles_outlined,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
      ),
    );
  }

  /// Opens the page and carries on making its subtitles once the film
  /// plays there.
  void _resume(SavedSubs s) {
    ActiveWork.forgetStopped(s.id);
    requestResume(s.page);
    toast(context, 'Mở trang, sẽ làm tiếp khi phim chạy');
  }

  void _view(SavedSubs s) => _open(
    title: s.title.isEmpty ? _host(s.page) : s.title,
    subtitle: '${_label(s)}\n${s.page}',
    cues: s.cues,
    saved: s,
    onDelete: () => SubtitleStore.delete(s.id),
  );

  Future<void> _webAction(SavedSubs s, String action) async {
    switch (action) {
      case 'view':
        _view(s);
      case 'open':
        requestOpenPage(s.page);
      case 'resume':
        _resume(s);
      case 'restart':
        if (await restartSubtitles(context, s)) await _reload();
      case 'rename':
        final name = await askText(context, 'Đổi tên', initial: s.title);
        if (name == null || name.isEmpty) return;
        final latest = await SubtitleStore.load(s.id) ?? s;
        await SubtitleStore.save(latest.withTitle(name));
        await _reload();
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Xoá phụ đề?'),
            content: Text(
              'Xoá phụ đề của "${s.title.isEmpty ? _host(s.page) : s.title}". '
              'Trang đã lưu không bị ảnh hưởng.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Huỷ'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Xoá'),
              ),
            ],
          ),
        );
        if (ok != true) return;
        await ActiveWork.stop(ActiveWork.find(s.id)?.session);
        await SubtitleStore.delete(s.id);
        await _reload();
    }
  }

  /// One web page's subtitles, like a saved page: a tap opens the page;
  /// "Làm tiếp" when part of the film is still missing.
  Widget _webRow(SavedSubs s) {
    final web = s.page.startsWith('http');
    return ListTile(
      leading: _picture(s),
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
            '${_date(s.updated)}'
            '${s.untranslated > 0 ? ' · ${s.untranslated} câu chưa dịch' : ''}',
          ),
        ],
      ),
      isThreeLine: true,
      trailing: ValueListenableBuilder(
        valueListenable: ActiveWork.all,
        builder: (context, _, _) {
          final running = ActiveWork.find(s.id) != null;
          final resume = web && s.canResume && !running;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (resume)
                TextButton(
                  onPressed: () => _resume(s),
                  child: const Text('Làm tiếp'),
                )
              else if (running)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 8),
                  child: Text('Đang làm'),
                ),
              PopupMenuButton<String>(
                tooltip: 'Thêm',
                onSelected: (v) => _webAction(s, v),
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'view',
                    child: Text('Xem / sửa phụ đề'),
                  ),
                  if (web)
                    const PopupMenuItem(value: 'open', child: Text('Mở trang')),
                  if (resume)
                    const PopupMenuItem(
                      value: 'resume',
                      child: Text('Làm tiếp'),
                    ),
                  if (web)
                    const PopupMenuItem(
                      value: 'restart',
                      child: Text('Làm lại từ đầu'),
                    ),
                  const PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
                  const PopupMenuItem(value: 'delete', child: Text('Xoá')),
                ],
              ),
            ],
          );
        },
      ),
      onTap: web ? () => requestOpenPage(s.page) : () => _view(s),
      onLongPress: () => _view(s),
    );
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
    VideoItem? item,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SubtitleView(
          title: title,
          subtitle: subtitle,
          cues: cues,
          saved: saved,
          item: item,
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
          IconButton(
            tooltip: 'Âm thanh lưu riêng',
            icon: const Icon(Icons.audio_file_outlined),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RetainedAudioScreen()),
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
                  const _StoppedCards(),
                  if (web.isNotEmpty) const _Section('Từ web'),
                  if (web.isNotEmpty)
                    const Padding(
                      padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                      child: Text(
                        'Bấm để mở trang · giữ lâu hoặc ⋯ để xem, sửa phụ đề',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  for (final s in web) _webRow(s),
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
                      subtitle: Text('${cues.length} dòng phụ đề'),
                      onTap: () => _open(
                        title: item.name,
                        subtitle: 'Video trong Thư viện',
                        item: item,
                        cues: cues,
                        onDelete: () async {
                          await ActiveWork.stop(
                            ActiveWork.find(
                              'file:${item.file.absolute.path}',
                            )?.session,
                          );
                          if (await item.srtFile.exists()) {
                            await item.srtFile.delete();
                          }
                          if (await item.subtitleDataFile.exists()) {
                            await item.subtitleDataFile.delete();
                          }
                        },
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
    this.item,
  });

  final String title;
  final String subtitle;
  final List<Cue> cues;
  final Future<void> Function() onDelete;

  /// Web entries can be renamed, translated again and edited.
  final SavedSubs? saved;
  final VideoItem? item;

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

  Future<String?> _ask(String heading, String initial, {int lines = 1}) =>
      askText(context, heading, initial: initial, lines: lines);

  Future<void> _rename() async {
    final s = saved;
    if (s == null) return;
    final name = await _ask('Đổi tên', title);
    if (name == null || name.isEmpty) return;
    final latest = await SubtitleStore.load(s.id) ?? s;
    await _store(latest.withTitle(name));
  }

  Future<void> _editLine(int i) async {
    if (saved == null && widget.item == null) return;
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
    await _storeCues(next);
  }

  Future<void> _storeCues(List<Cue> next) async {
    if (saved case final SavedSubs s) {
      ActiveWork.find(s.id)?.session.applyCues(next);
      await _store(s.withCues(next));
    } else if (widget.item case final VideoItem item) {
      ActiveWork.find(
        'file:${item.file.absolute.path}',
      )?.session.applyCues(next);
      await VideoLibrary.saveCues(item, next);
      if (mounted) setState(() => cues = next);
    }
  }

  Future<void> _revise({int? index, bool onlyMissing = false}) async {
    final selected = index == null ? null : cues[index];
    final id = saved?.id ?? 'file:${widget.item!.file.absolute.path}';
    final language =
        saved?.language ?? await VideoLibrary.subtitleLanguage(widget.item!);
    if (!mounted) return;
    await showSubtitleRevision(
      context,
      videoId: id,
      language: language,
      initialIndex: index,
      initialCue: selected,
      onlyMissing: onlyMissing,
      currentCues: () => List.of(ActiveWork.find(id)?.session.cues ?? cues),
      onApply: _storeCues,
    );
  }

  Future<void> _changeLanguage() async {
    final current =
        saved?.language ?? await VideoLibrary.subtitleLanguage(widget.item!);
    if (!mounted) return;
    final code = await chooseVideoLanguage(context, current);
    if (code == null || !mounted) return;
    final id = saved?.id ?? 'file:${widget.item!.file.absolute.path}';
    final running = ActiveWork.find(id);
    if (running != null) {
      await running.session.selectLanguage(code);
      await ActiveWork.persist(id);
      if (mounted) setState(() => cues = List.of(running.session.cues));
    }
    if (saved case final SavedSubs s) {
      await _store(s.withLanguage(code).withCues(cues));
    } else {
      await VideoLibrary.saveCues(widget.item!, cues, language: code);
    }
  }

  Future<void> _lineActions(int index) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'Câu ${index + 1} · ${formatTime(cues[index].start)}',
              ),
            ),
            ListTile(
              leading: const Icon(Icons.translate),
              title: const Text('Yêu cầu dịch lại câu này…'),
              onTap: () => Navigator.pop(context, 'revise'),
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Sửa bằng tay'),
              onTap: () => Navigator.pop(context, 'edit'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (action == 'revise') await _revise(index: index);
    if (action == 'edit') await _editLine(index);
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
          if (saved != null || widget.item != null)
            IconButton(
              tooltip: 'Yêu cầu dịch lại',
              icon: const Icon(Icons.translate),
              onPressed: () => _revise(),
            ),
          if (saved case final SavedSubs s
              when s.page.startsWith('http') &&
                  s.canResume &&
                  ActiveWork.find(s.id) == null)
            IconButton(
              tooltip: 'Làm tiếp',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () {
                ActiveWork.forgetStopped(s.id);
                requestResume(s.page);
                toast(context, 'Mở trang, sẽ làm tiếp khi phim chạy');
                Navigator.popUntil(context, (r) => r.isFirst);
              },
            ),
          if (saved?.page.startsWith('http') ?? false)
            IconButton(
              tooltip: 'Mở trang này để xem',
              icon: const Icon(Icons.open_in_browser),
              onPressed: () {
                requestOpenPage(saved!.page);
                Navigator.popUntil(context, (r) => r.isFirst);
              },
            ),
          PopupMenuButton<String>(
            tooltip: 'Thêm',
            onSelected: (v) async {
              switch (v) {
                case 'restart':
                  if (await restartSubtitles(context, saved!) &&
                      context.mounted) {
                    Navigator.popUntil(context, (r) => r.isFirst);
                  }
                case 'language':
                  await _changeLanguage();
                case 'rename':
                  await _rename();
                case 'export':
                  await _export(context);
                case 'delete':
                  await _delete(context);
              }
            },
            itemBuilder: (_) => [
              if (saved?.page.startsWith('http') ?? false)
                const PopupMenuItem(
                  value: 'restart',
                  child: ListTile(
                    leading: Icon(Icons.restart_alt),
                    title: Text('Làm lại từ đầu'),
                  ),
                ),
              if (saved != null || widget.item != null)
                const PopupMenuItem(
                  value: 'language',
                  child: ListTile(
                    leading: Icon(Icons.language),
                    title: Text('Ngôn ngữ của video'),
                  ),
                ),
              if (saved != null)
                const PopupMenuItem(
                  value: 'rename',
                  child: ListTile(
                    leading: Icon(Icons.drive_file_rename_outline),
                    title: Text('Đổi tên'),
                  ),
                ),
              PopupMenuItem(
                value: 'export',
                enabled: cues.isNotEmpty,
                child: const ListTile(
                  leading: Icon(Icons.download_outlined),
                  title: Text('Lưu file .srt'),
                ),
              ),
              const PopupMenuItem(
                value: 'delete',
                child: ListTile(
                  leading: Icon(Icons.delete_outline),
                  title: Text('Xoá'),
                ),
              ),
            ],
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
                  // Only the lines that failed, never the whole film.
                  onPressed: () => _revise(onlyMissing: true),
                  child: const Text('Dịch lại'),
                ),
              ],
            ),
          if (saved != null || widget.item != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                'Chạm vào một dòng để sửa hoặc yêu cầu dịch lại',
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: CueList(
              cues: cues,
              onTap: saved == null && widget.item == null ? null : _lineActions,
            ),
          ),
        ],
      ),
    );
  }
}

/// All independent video pipelines, including those whose pages were closed.
class _ActiveCard extends StatelessWidget {
  const _ActiveCard();
  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ActiveWork.all,
    builder: (context, works, _) => Column(
      children: [
        for (final work in works.where((work) => !work.hidden))
          _WorkCard(work: work),
      ],
    ),
  );
}

class _WorkCard extends StatelessWidget {
  const _WorkCard({required this.work});
  final ActiveWork work;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: work.session,
    builder: (context, _) {
      final session = work.session;
      return Card(
        margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  ActivityIcon(session: session, title: work.title),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      work.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Chi tiết phụ đề',
                    icon: const Icon(Icons.info_outline),
                    onPressed: () => showSessionDetails(context, session),
                  ),
                  TextButton(
                    onPressed: () => ActiveWork.stop(session),
                    child: const Text('Dừng dịch'),
                  ),
                ],
              ),
              Text(session.languageNotice),
              if (session.duration > 0)
                CoverageBar(
                  covered: session.covered,
                  duration: session.duration,
                  done: coversWholeVideo(
                    session.covered,
                    session.duration,
                    reachedEnd: session.reachedEnd,
                  ),
                ),
              Text(
                '${session.stage} · ${session.cues.length} dòng',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      );
    },
  );
}

/// Work the user stopped: what was made is kept, and it can carry on.
class _StoppedCards extends StatelessWidget {
  const _StoppedCards();

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: ActiveWork.stopped,
    builder: (context, works, _) => Column(
      children: [
        for (final w in works)
          Card(
            margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: ListTile(
              leading: const Icon(Icons.pause_circle_outline),
              title: Text(
                'Đã dừng: ${w.title}',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(w.label),
              trailing: Wrap(
                spacing: 4,
                children: [
                  TextButton(
                    onPressed: () {
                      ActiveWork.forgetStopped(w.id);
                      requestResume(w.page);
                      toast(context, 'Mở trang, sẽ làm tiếp khi phim chạy');
                    },
                    child: const Text('Làm tiếp'),
                  ),
                  IconButton(
                    tooltip: 'Ẩn khỏi danh sách',
                    icon: const Icon(Icons.close),
                    onPressed: () => ActiveWork.forgetStopped(w.id),
                  ),
                ],
              ),
            ),
          ),
      ],
    ),
  );
}
