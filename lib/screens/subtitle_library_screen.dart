import 'dart:async';

import 'package:flutter/material.dart';

import '../widgets/session_retry.dart';
import '../services/active_work.dart';
import '../services/open_page.dart';
import '../widgets/activity_icon.dart';
import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/app_settings.dart';
import '../services/bookmarks.dart';
import '../services/retained_audio.dart';
import '../services/subtitle_store.dart';
import '../services/subtitle_resume.dart';
import '../widgets/subtitle_resume.dart';
import '../services/translator.dart';
import '../services/video_library.dart';
import '../widgets/bookmarks_sheet.dart';
import '../widgets/common.dart';
import '../widgets/picture_picker.dart';
import '../widgets/asset_marks.dart';
import '../widgets/folder_group.dart';
import 'downloads_screen.dart';
import 'retained_audio_screen.dart';
import '../widgets/subtitle_details.dart';
import '../widgets/subtitle_revision.dart';
import '../widgets/video_language.dart';

/// "Làm lại từ đầu": after asking, stops any work on [s], deletes its
/// lines and opens the page to make them again from the start of the
/// film. True when it went ahead.
Future<bool> restartSubtitles(
  BuildContext context,
  SubsHeader s, {
  required int lines,
}) async {
  final name = s.title.isEmpty ? (Uri.tryParse(s.page)?.host ?? '') : s.title;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Làm lại từ đầu?'),
      content: Text(
        'Xoá $lines dòng phụ đề của "$name" rồi nghe và dịch lại '
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
  const SubtitleLibraryScreen({super.key, this.visit = 0});

  final int visit;

  @override
  State<SubtitleLibraryScreen> createState() => _SubtitleLibraryScreenState();
}

class _SubtitleLibraryScreenState extends State<SubtitleLibraryScreen> {
  List<SubsInfo>? _web;
  List<(VideoItem, int)> _videos = [];
  final _videoTranslated = <String, bool>{};
  Map<String, String> _folderOf = {};
  Map<String, int> _audio = {};
  int _bytes = 0;
  String? _thumbs;

  /// Folders opened to show their subtitles.
  final _expanded = <String>{};

  /// Subtitles picked for an action on several at once.
  final _picked = <String>{};
  bool get _picking => _picked.isNotEmpty;
  Timer? _soon;
  String _filter = 'all';

  @override
  void didUpdateWidget(covariant SubtitleLibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.visit != widget.visit) unawaited(_reload());
  }

  @override
  void initState() {
    super.initState();
    _reload();
    Bookmarks.thumbDir().then((dir) {
      if (mounted && dir != null) setState(() => _thumbs = dir.path);
    });
    SubtitleStore.changes.addListener(_changedSoon);
    RetainedAudioStore.changes.addListener(_changedSoon);
    Bookmarks.pictureChanges.addListener(_changedSoon);
    ActiveWork.all.addListener(_changedSoon);
  }

  @override
  void dispose() {
    SubtitleStore.changes.removeListener(_changedSoon);
    RetainedAudioStore.changes.removeListener(_changedSoon);
    Bookmarks.pictureChanges.removeListener(_changedSoon);
    ActiveWork.all.removeListener(_changedSoon);
    _soon?.cancel();
    super.dispose();
  }

  /// Work running elsewhere saves every few seconds: refresh a little
  /// later, not on every save.
  void _changedSoon() {
    _soon ??= Timer(const Duration(seconds: 3), () {
      _soon = null;
      if (mounted) unawaited(_reload());
    });
  }

  Future<void> _reload() async {
    // Summaries only (no lines are unpacked): fast even with many films.
    final results = await Future.wait<Object>([
      SubtitleStore.summaries(),
      SubtitleStore.storageBytes(),
      Bookmarks.subtitleFolders(),
      RetainedAudioStore.instance
          .list()
          .then<Object>(
            (all) => {
              for (final a in all)
                if (a.bytes > 0) a.videoId: a.bytes,
            },
          )
          .catchError((Object _) => <String, int>{}),
    ]);
    if (!mounted) return;
    final web = results[0] as List<SubsInfo>;
    setState(() {
      _web = web;
      _bytes = results[1] as int;
      _folderOf = results[2] as Map<String, String>;
      _audio = results[3] as Map<String, int>;
      _picked.removeWhere((id) => !web.any((s) => s.id == id));
    });
    // Library videos after: the web list is already on screen.
    final items = (await VideoLibrary.list(
      hidden: false,
    )).where((item) => item.srtFile.existsSync()).toList();
    final counts = await Future.wait([
      for (final item in items)
        VideoLibrary.loadCues(item).then((c) {
          _videoTranslated[item.file.absolute.path] = c.any(
            (line) => line.source.isEmpty || line.source != line.text,
          );
          return c.length;
        }),
    ]);
    if (!mounted) return;
    setState(
      () => _videos = [
        for (var i = 0; i < items.length; i++) (items[i], counts[i]),
      ],
    );
  }

  String _date(DateTime d) =>
      '${d.day}/${d.month}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  String _label(SubsInfo s) => s.imported
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
  String _name(SubsInfo s) => s.title.isEmpty ? _host(s.page) : s.title;

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

  /// The page's picture (taken when it was saved or its subtitles began).
  Widget _picture(SubsInfo s) => StoredPicture(
    pictureKey: Bookmarks.subtitlePictureKey(s.id),
    fallbackKey: s.page,
    directory: _thumbs,
    placeholder: const ColoredBox(
      color: Color(0x223D7DFF),
      child: Icon(Icons.subtitles_outlined),
    ),
  );

  Future<void> _resume(SubsInfo s) async {
    await resumeStoredSubtitles(context, s.id);
  }

  Future<void> _view(SubsInfo info) async {
    final s = await SubtitleStore.load(info.id);
    if (s == null || !mounted) return;
    await _open(
      title: _name(info),
      subtitle: '${_label(info)}\n${s.page}',
      cues: s.cues,
      saved: s,
      onDelete: () => SubtitleStore.delete(s.id),
    );
  }

  Future<void> _deleteAudio(Iterable<String> ids) async {
    for (final id in ids) {
      await ActiveWork.stop(ActiveWork.find(id)?.session);
      await RetainedAudioStore.instance.deleteConfirmed(id);
    }
  }

  Future<void> _webAction(SubsInfo s, String action) async {
    switch (action) {
      case 'picture':
        await editStoredPicture(
          context,
          Bookmarks.subtitlePictureKey(s.id),
          fallbackKey: s.page,
        );
        if (mounted) setState(() {});
      case 'view':
        await _view(s);
      case 'open':
        requestOpenPage(s.page);
      case 'resume':
        _resume(s);
      case 'prefer':
        final session = ActiveWork.find(s.id)?.session;
        if (session != null) session.preferred = !session.preferred;
      case 'restart':
        if (await restartSubtitles(context, s, lines: s.lines)) await _reload();
      case 'folder':
        final folder = await pickFolder(
          context,
          current: _folderOf[s.id] ?? '',
        );
        if (folder == null) return;
        await Bookmarks.moveSubtitles([s.id], folder);
        if (folder.isNotEmpty) _expanded.add(folder);
        await _reload();
      case 'rename':
        final name = await askText(context, 'Đổi tên', initial: s.title);
        if (name == null || name.isEmpty) return;
        final latest = await SubtitleStore.load(s.id);
        if (latest == null) return;
        await SubtitleStore.save(latest.withTitle(name));
        await _reload();
      case 'audio':
        if (!mounted) return;
        if (!await confirmMany(
          context,
          'Xoá âm thanh đã giữ?',
          'Xoá ${_size(_audio[s.id] ?? 0)} âm thanh của "${_name(s)}". '
              'Phụ đề vẫn còn; nhận dạng lại thì app lấy lại âm thanh từ video.',
        )) {
          return;
        }
        await _deleteAudio([s.id]);
        await _reload();
      case 'delete':
        if (!await confirmMany(
          context,
          'Xoá phụ đề?',
          'Xoá phụ đề của "${_name(s)}". Trang đã lưu không bị ảnh hưởng.',
        )) {
          return;
        }
        await ActiveWork.stop(ActiveWork.find(s.id)?.session);
        await SubtitleStore.delete(s.id);
        await _reload();
    }
  }

  // ---- several at once ----

  List<SubsInfo> get _pickedEntries => (_web ?? const <SubsInfo>[])
      .where((s) => _picked.contains(s.id))
      .toList();

  void _toggle(String id) => setState(() {
    if (!_picked.remove(id)) _picked.add(id);
  });

  Future<void> _manyAction(String action) async {
    final chosen = _pickedEntries;
    if (chosen.isEmpty) return;
    switch (action) {
      case 'resume':
        final eligible = chosen
            .where((s) => s.canResume && ActiveWork.find(s.id) == null)
            .toList();
        if (eligible.isEmpty) {
          toast(context, 'Các phụ đề đã chọn không còn gì để làm tiếp');
          return;
        }
        final pages = <String>[];
        for (final s in eligible) {
          if (!mounted) return;
          final result = await resumeStoredSubtitles(
            context,
            s.id,
            openSource: false,
          );
          if (result == SubtitleResumeResult.needsSource &&
              s.page.startsWith('http')) {
            pages.add(s.page);
          }
        }
        if (pages.isNotEmpty) {
          requestResumeAll(pages);
          if (mounted) {
            toast(
              context,
              '${pages.length} trang còn thiếu âm thanh; các video có dữ liệu được làm tiếp trong app',
            );
          }
        }
      case 'stop':
        final running = [
          for (final s in chosen) ?ActiveWork.find(s.id)?.session,
        ];
        if (running.isEmpty) {
          toast(context, 'Không có phụ đề nào đang làm trong số đã chọn');
          return;
        }
        await Future.wait([for (final s in running) ActiveWork.stop(s)]);
        if (mounted) toast(context, 'Đã dừng ${running.length} phụ đề');
      case 'prefer':
        final running = [
          for (final s in chosen) ?ActiveWork.find(s.id)?.session,
        ];
        if (running.isEmpty) {
          toast(context, 'Ưu tiên dành cho phim đang làm');
          return;
        }
        // Picked together: these go first, the others give way.
        final on = !running.every((s) => s.preferred);
        for (final s in running) {
          s.preferred = on;
        }
        if (mounted) {
          toast(
            context,
            on
                ? 'Ưu tiên ${running.length} phim đã chọn'
                : 'Bỏ ưu tiên ${running.length} phim',
          );
        }
      case 'open':
        requestOpenPages([
          for (final s in chosen)
            if (s.page.startsWith('http')) s.page,
        ]);
      case 'folder':
        final folder = await pickFolder(context);
        if (folder == null) return;
        await Bookmarks.moveSubtitles([for (final s in chosen) s.id], folder);
        if (folder.isNotEmpty) _expanded.add(folder);
      case 'audio':
        final withAudio = [
          for (final s in chosen)
            if (_audio.containsKey(s.id)) s.id,
        ];
        if (withAudio.isEmpty) {
          toast(context, 'Các phụ đề đã chọn không có âm thanh giữ lại');
          return;
        }
        final bytes = withAudio.fold<int>(0, (n, id) => n + (_audio[id] ?? 0));
        if (!await confirmMany(
          context,
          'Xoá âm thanh đã giữ?',
          'Xoá ${_size(bytes)} âm thanh của ${withAudio.length} phim. '
              'Phụ đề vẫn còn.',
        )) {
          return;
        }
        await _deleteAudio(withAudio);
      case 'delete':
        if (!await confirmMany(
          context,
          'Xoá ${chosen.length} phụ đề?',
          'Xoá phụ đề của ${chosen.length} phim đã chọn. Phim đang làm sẽ '
              'dừng trước. Trang đã lưu không bị ảnh hưởng.',
        )) {
          return;
        }
        for (final s in chosen) {
          await ActiveWork.stop(ActiveWork.find(s.id)?.session);
          await SubtitleStore.delete(s.id);
        }
    }
    if (!mounted) return;
    setState(_picked.clear);
    await _reload();
  }

  Future<void> _folderAction(String folder, String action) async {
    if (action == 'rename') {
      final name = await askText(context, 'Đổi tên thư mục', initial: folder);
      if (name == null || name.isEmpty || name == folder) return;
      final renamed = await Bookmarks.renameFolder(folder, name);
      if (renamed && _expanded.remove(folder)) _expanded.add(name.trim());
      if (!renamed && mounted) {
        toast(context, 'Tên thư mục trống hoặc đã có');
      }
    } else if (action == 'delete') {
      if (!await confirmMany(
        context,
        'Xoá thư mục "$folder"?',
        'Phụ đề và trang trong thư mục được đưa ra ngoài, không bị xoá.',
      )) {
        return;
      }
      await Bookmarks.deleteFolder(folder);
      _expanded.remove(folder);
    } else if (action == 'pick') {
      setState(() {
        for (final s in _web ?? const <SubsInfo>[]) {
          if (_folderOf[s.id] == folder) _picked.add(s.id);
        }
      });
      return;
    }
    await _reload();
  }

  /// One web page's subtitles, like a saved page: a tap opens the page;
  /// "Làm tiếp" when part of the film is still missing. A long press starts
  /// picking several.
  Widget _webRow(SubsInfo s) {
    final web = s.page.startsWith('http');
    final picked = _picked.contains(s.id);
    final audio = _audio[s.id];
    return ListTile(
      selected: picked,
      leading: _picking
          ? Checkbox(value: picked, onChanged: (_) => _toggle(s.id))
          : _picture(s),
      title: Text(_name(s), maxLines: 2, overflow: TextOverflow.ellipsis),
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
          AssetMarks(
            translated: s.lines > s.untranslated,
            audio: (audio ?? 0) > 0,
          ),
          Text(
            '${s.lines} dòng · '
            '${kLanguages[s.language] ?? s.language} · '
            '${_date(s.updated)}'
            '${s.untranslated > 0 ? ' · ${s.untranslated} câu chưa dịch' : ''}'
            '${audio != null ? ' · chưa xoá âm thanh ${_size(audio)}' : ''}',
          ),
        ],
      ),
      isThreeLine: true,
      trailing: _picking
          ? null
          : ValueListenableBuilder(
              valueListenable: ActiveWork.all,
              builder: (context, _, _) {
                final running = ActiveWork.find(s.id) != null;
                final resume = s.canResume && !running;
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
                          value: 'picture',
                          child: Text('Đổi ảnh đại diện'),
                        ),
                        const PopupMenuItem(
                          value: 'view',
                          child: Text('Xem / sửa phụ đề'),
                        ),
                        if (web)
                          const PopupMenuItem(
                            value: 'open',
                            child: Text('Mở trang'),
                          ),
                        if (resume)
                          const PopupMenuItem(
                            value: 'resume',
                            child: Text('Làm tiếp'),
                          ),
                        if (running)
                          CheckedPopupMenuItem(
                            value: 'prefer',
                            checked:
                                ActiveWork.find(s.id)?.session.preferred ??
                                false,
                            child: const Text('Ưu tiên phim này'),
                          ),
                        if (web)
                          const PopupMenuItem(
                            value: 'restart',
                            child: Text('Làm lại từ đầu'),
                          ),
                        const PopupMenuItem(
                          value: 'folder',
                          child: Text('Chuyển vào thư mục…'),
                        ),
                        const PopupMenuItem(
                          value: 'rename',
                          child: Text('Đổi tên'),
                        ),
                        if (audio != null)
                          const PopupMenuItem(
                            value: 'audio',
                            child: Text('Xoá âm thanh đã giữ'),
                          ),
                        const PopupMenuItem(
                          value: 'delete',
                          child: Text('Xoá'),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
      onTap: _picking
          ? () => _toggle(s.id)
          : web
          ? () => requestOpenPage(s.page)
          : () => _view(s),
      onLongPress: () => _toggle(s.id),
    );
  }

  Widget _folderRow(String folder, int count) {
    final open = _expanded.contains(folder) || _picking;
    return FolderGroupHeader(
      expanded: open,
      title: folder,
      subtitle: '$count phụ đề',
      onTap: () => setState(() {
        if (!_expanded.remove(folder)) _expanded.add(folder);
      }),
      actions: PopupMenuButton<String>(
        tooltip: 'Sửa thư mục',
        onSelected: (v) => _folderAction(folder, v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'pick', child: Text('Chọn cả thư mục')),
          PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
          PopupMenuItem(value: 'delete', child: Text('Xoá thư mục')),
        ],
      ),
    );
  }

  Widget _videoRow(VideoItem item, int count) => ListTile(
    leading: StoredPicture(
      pictureKey: Bookmarks.subtitlePictureKey(
        'file:${item.file.absolute.path}',
      ),
      directory: _thumbs,
      placeholder: const Icon(Icons.movie_outlined),
    ),
    title: Text(item.name, maxLines: 2, overflow: TextOverflow.ellipsis),
    subtitle: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$count dòng phụ đề'),
        AssetMarks(
          translated: _videoTranslated[item.file.absolute.path] ?? false,
          audio: (_audio['file:${item.file.absolute.path}'] ?? 0) > 0,
        ),
      ],
    ),
    trailing: IconButton(
      tooltip: 'Đổi ảnh đại diện',
      icon: const Icon(Icons.image_outlined),
      onPressed: () async {
        await editStoredPicture(
          context,
          Bookmarks.subtitlePictureKey('file:${item.file.absolute.path}'),
        );
        if (mounted) setState(() {});
      },
    ),
    onTap: () async {
      final cues = await VideoLibrary.loadCues(item);
      if (!mounted) return;
      await _open(
        title: item.name,
        subtitle: 'Video trong Thư viện',
        item: item,
        cues: cues,
        onDelete: () async {
          await ActiveWork.stop(
            ActiveWork.find('file:${item.file.absolute.path}')?.session,
          );
          if (await item.srtFile.exists()) await item.srtFile.delete();
          if (await item.subtitleDataFile.exists()) {
            await item.subtitleDataFile.delete();
          }
        },
      );
    },
  );

  Widget _filters() {
    final web = _web ?? const <SubsInfo>[];
    final unclassified =
        web.where((s) => (_folderOf[s.id] ?? '').isEmpty).length +
        _videos.length;
    final retained =
        web.where((s) => _audio.containsKey(s.id)).length +
        _videos
            .where((v) => _audio.containsKey('file:${v.$1.file.absolute.path}'))
            .length;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final choice in [
            ('all', 'Tất cả'),
            ('unclassified', 'Chưa phân loại ($unclassified)'),
            ('audio', 'Chưa xoá âm thanh ($retained)'),
          ])
            ChoiceChip(
              label: Text(choice.$2),
              selected: _filter == choice.$1,
              onSelected: (_) => setState(() => _filter = choice.$1),
            ),
        ],
      ),
    );
  }

  /// Rows of the list, built only as they scroll into view.
  List<Widget Function()> _rows(List<SubsInfo> web) {
    web = web
        .where(
          (s) => switch (_filter) {
            'unclassified' => (_folderOf[s.id] ?? '').isEmpty,
            'audio' => _audio.containsKey(s.id),
            _ => true,
          },
        )
        .toList();
    final videos = _videos
        .where(
          (v) =>
              _filter != 'audio' ||
              _audio.containsKey('file:${v.$1.file.absolute.path}'),
        )
        .toList();
    final rows = <Widget Function()>[
      if (!_picking) _filters,
      () => const _ActiveCard(),
      () => const _StoppedCards(),
    ];
    if (web.isNotEmpty) {
      rows
        ..add(() => const _Section('Từ web'))
        ..add(
          () => const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: Text(
              'Bấm để mở trang · giữ lâu để chọn nhiều · ⋯ để xem, sửa',
              style: TextStyle(fontSize: 12),
            ),
          ),
        );
      final byFolder = <String, List<SubsInfo>>{};
      final top = <SubsInfo>[];
      for (final s in web) {
        final f = _folderOf[s.id];
        if (f == null || f.isEmpty) {
          top.add(s);
        } else {
          byFolder.putIfAbsent(f, () => []).add(s);
        }
      }
      for (final folder in byFolder.keys.toList()..sort()) {
        final list = byFolder[folder]!;
        rows.add(() => _folderRow(folder, list.length));
        if (_expanded.contains(folder) || _picking) {
          for (final s in list) {
            rows.add(
              () => FolderGroupEntry(last: s == list.last, child: _webRow(s)),
            );
          }
        }
      }
      if (top.isNotEmpty) {
        rows.add(
          () => FolderGroupHeader(
            title: 'Chưa phân loại',
            subtitle: '${top.length} phụ đề',
            expanded: true,
          ),
        );
        for (final s in top) {
          rows.add(
            () => FolderGroupEntry(last: s == top.last, child: _webRow(s)),
          );
        }
      }
    }
    if (videos.isNotEmpty && !_picking) {
      rows.add(() => const _Section('Video trong Thư viện'));
      for (final (item, count) in videos) {
        rows.add(() => _videoRow(item, count));
      }
    }
    if (web.isEmpty && videos.isEmpty) {
      rows.add(
        () => const ListTile(title: Text('Chưa có phụ đề trong mục này')),
      );
    }
    return rows;
  }

  PreferredSizeWidget _appBar(List<SubsInfo>? web) {
    if (_picking) {
      final chosen = _pickedEntries;
      final canResume = chosen.any(
        (s) =>
            s.page.startsWith('http') &&
            s.canResume &&
            ActiveWork.find(s.id) == null,
      );
      final running = chosen.any((s) => ActiveWork.find(s.id) != null);
      return selectionBar(
        context,
        count: _picked.length,
        onDone: () => setState(_picked.clear),
        onAll: () => setState(
          () =>
              _picked.addAll([for (final s in web ?? const <SubsInfo>[]) s.id]),
        ),
        actions: [
          if (canResume)
            IconButton(
              tooltip: 'Làm tiếp',
              icon: const Icon(Icons.play_arrow),
              onPressed: () => _manyAction('resume'),
            ),
          if (running)
            IconButton(
              tooltip: 'Ưu tiên',
              icon: const Icon(Icons.keyboard_double_arrow_up),
              onPressed: () => _manyAction('prefer'),
            ),
          if (running)
            IconButton(
              tooltip: 'Dừng',
              icon: const Icon(Icons.stop),
              onPressed: () => _manyAction('stop'),
            ),
          PopupMenuButton<String>(
            tooltip: 'Thêm',
            onSelected: _manyAction,
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'open', child: Text('Mở các trang')),
              const PopupMenuItem(
                value: 'folder',
                child: Text('Chuyển vào thư mục…'),
              ),
              if (chosen.any((s) => _audio.containsKey(s.id)))
                const PopupMenuItem(
                  value: 'audio',
                  child: Text('Xoá âm thanh đã giữ'),
                ),
              const PopupMenuItem(value: 'delete', child: Text('Xoá phụ đề')),
            ],
          ),
        ],
      );
    }
    return AppBar(
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Kho phụ đề'),
          if (web != null && web.isNotEmpty)
            Text(
              '${web.length} phim · ${_size(_bytes)}',
              style: Theme.of(context).textTheme.labelSmall,
            ),
        ],
      ),
      actions: [
        if (web != null && web.isNotEmpty)
          IconButton(
            tooltip: 'Chọn nhiều',
            icon: const Icon(Icons.checklist),
            onPressed: () => setState(() => _picked.add(web.first.id)),
          ),
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
          ).then((_) => _reload()),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final web = _web;
    return PopScope(
      canPop: !_picking,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) setState(_picked.clear);
      },
      child: Scaffold(
        appBar: _appBar(web),
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
                child: Builder(
                  builder: (context) {
                    final rows = _rows(web);
                    return ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) => rows[i](),
                    );
                  },
                ),
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
              when s.canResume && ActiveWork.find(s.id) == null)
            IconButton(
              tooltip: 'Làm tiếp',
              icon: const Icon(Icons.play_circle_outline),
              onPressed: () async {
                final result = await resumeStoredSubtitles(context, s.id);
                if (!context.mounted) return;
                if (result == SubtitleResumeResult.needsSource &&
                    s.page.startsWith('http')) {
                  Navigator.popUntil(context, (r) => r.isFirst);
                } else if (result == SubtitleResumeResult.started ||
                    result == SubtitleResumeResult.alreadyRunning) {
                  Navigator.pop(context);
                }
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
                  if (await restartSubtitles(
                        context,
                        saved!,
                        lines: saved!.cues.length,
                      ) &&
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
                    tooltip: session.preferred
                        ? 'Bỏ ưu tiên phim này'
                        : 'Ưu tiên phim này',
                    isSelected: session.preferred,
                    icon: const Icon(Icons.keyboard_double_arrow_up),
                    selectedIcon: const Icon(
                      Icons.keyboard_double_arrow_up,
                      color: Colors.orange,
                    ),
                    onPressed: () => session.preferred = !session.preferred,
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
              if (session.needsAudioSource &&
                  (work.saver?.page.startsWith('http') ?? false))
                TextButton.icon(
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Lấy âm thanh còn thiếu từ web'),
                  onPressed: () async {
                    final page = work.saver!.page;
                    await ActiveWork.stop(session);
                    requestResume(page);
                  },
                ),
              SessionRetryButton(session: session),
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
                    onPressed: () => resumeStoredSubtitles(context, w.id),
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
