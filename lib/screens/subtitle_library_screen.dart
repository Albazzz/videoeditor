import 'package:flutter/material.dart';

import '../models/cue.dart';
import '../services/app_settings.dart';
import '../services/subtitle_store.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';
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

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final web = await SubtitleStore.list();
    final videos = <(VideoItem, List<Cue>)>[];
    for (final item in await VideoLibrary.list(hidden: false)) {
      if (!item.srtFile.existsSync()) continue;
      videos.add((item, await VideoLibrary.loadCues(item)));
    }
    if (!mounted) return;
    setState(() {
      _web = web;
      _videos = videos;
    });
  }

  String _date(DateTime d) =>
      '${d.day}/${d.month}/${d.year} '
      '${d.hour.toString().padLeft(2, '0')}:'
      '${d.minute.toString().padLeft(2, '0')}';

  String _host(String page) => Uri.tryParse(page)?.host ?? page;

  Future<void> _open({
    required String title,
    required String subtitle,
    required List<Cue> cues,
    required Future<void> Function() onDelete,
  }) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _SubtitleView(
          title: title,
          subtitle: subtitle,
          cues: cues,
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
      appBar: AppBar(title: const Text('Kho phụ đề')),
      body: web == null
          ? const Center(child: CircularProgressIndicator())
          : web.isEmpty && _videos.isEmpty
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
                  if (web.isNotEmpty) const _Section('Từ web'),
                  for (final s in web)
                    ListTile(
                      leading: const Icon(Icons.public),
                      title: Text(
                        s.title.isEmpty ? _host(s.page) : s.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${s.cues.length} dòng · '
                        '${kLanguages[s.language] ?? s.language} · '
                        '${_date(s.updated)}',
                      ),
                      onTap: () => _open(
                        title: s.title.isEmpty ? _host(s.page) : s.title,
                        subtitle: s.page,
                        cues: s.cues,
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
                      subtitle: Text('${cues.length} dòng'),
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

class _SubtitleView extends StatelessWidget {
  const _SubtitleView({
    required this.title,
    required this.subtitle,
    required this.cues,
    required this.onDelete,
  });

  final String title;
  final String subtitle;
  final List<Cue> cues;
  final Future<void> Function() onDelete;

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
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
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
          const Divider(height: 1),
          Expanded(child: CueList(cues: cues)),
        ],
      ),
    );
  }
}
