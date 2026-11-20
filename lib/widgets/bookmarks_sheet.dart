import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/bookmarks.dart';
import '../services/subtitle_store.dart';
import 'common.dart';

/// The saved pages; returns the address to open, or null.
Future<String?> showBookmarks(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * 0.75,
          child: BookmarksView(onOpen: (url) => Navigator.pop(context, url)),
        ),
      ),
    );

/// Asks where to save a page before saving it: its name and a folder
/// (with a way to make a new one). Returns (title, folder) or null.
Future<(String, String)?> askBookmarkPlace(
  BuildContext context,
  String title,
) async {
  final folders = await Bookmarks.folders();
  var folder = await Bookmarks.lastFolder();
  if (!context.mounted) return null;
  final name = TextEditingController(text: title);
  final result = await showDialog<(String, String)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Lưu trang vào đâu?'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ClearableField(controller: name, label: 'Tên trang'),
              const SizedBox(height: 8),
              RadioGroup<String>(
                groupValue: folder,
                onChanged: (v) => setState(() => folder = v ?? ''),
                child: Column(
                  children: [
                    for (final f in ['', ...folders])
                      RadioListTile<String>(
                        contentPadding: EdgeInsets.zero,
                        value: f,
                        secondary: Icon(
                          f.isEmpty ? Icons.star_outline : Icons.folder,
                        ),
                        title: Text(
                          _folderName(f),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('Thư mục mới…'),
                onPressed: () async {
                  final made = await _askName(ctx, 'Thư mục mới');
                  if (made == null || made.isEmpty) return;
                  await Bookmarks.createFolder(made);
                  if (!folders.contains(made)) folders.add(made);
                  setState(() => folder = made);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, (name.text.trim(), folder)),
            child: const Text('Lưu'),
          ),
        ],
      ),
    ),
  );
  return result;
}

String _folderName(String folder) => folder.isEmpty ? 'Ngoài cùng' : folder;

Future<String?> _askName(
  BuildContext context,
  String label, [
  String name = '',
]) => askText(context, label, initial: name);

/// Also used by the action immediately after a page is saved.
Future<void> editBookmark(
  BuildContext context,
  Bookmark bookmark, {
  bool editName = true,
}) async {
  final folders = await Bookmarks.folders();
  if (!context.mounted) return;
  var folder = folders.contains(bookmark.folder) ? bookmark.folder : '';
  final title = TextEditingController(text: bookmark.title);
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(editName ? 'Sửa trang đã lưu' : 'Chuyển vào thư mục'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editName) ClearableField(controller: title, label: 'Tên trang'),
          DropdownButtonFormField<String>(
            initialValue: folder,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Thư mục'),
            items: [
              for (final f in ['', ...folders])
                DropdownMenuItem(
                  value: f,
                  child: Text(_folderName(f), overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (v) => folder = v ?? '',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Lưu'),
        ),
      ],
    ),
  );
  if (ok == true) {
    await Bookmarks.update(
      bookmark.url,
      title: editName ? title.text.trim() : null,
      folder: folder,
    );
  }
}

/// Saved pages grouped by folder, with search and editing. Used in the
/// browser's sheet and as the "Trang lưu" tab.
class BookmarksView extends StatefulWidget {
  const BookmarksView({super.key, required this.onOpen});

  /// A page was tapped.
  final void Function(String url) onOpen;

  @override
  State<BookmarksView> createState() => _BookmarksViewState();
}

class _BookmarksViewState extends State<BookmarksView> {
  List<Bookmark>? _all;
  String? _thumbs;
  List<String> _folders = [];
  final _expanded = <String>{};
  String _filter = '';

  /// Pages with subtitles in the store, by address.
  Map<String, PageSubs> _subs = const {};
  Timer? _subsSoon;

  @override
  void initState() {
    super.initState();
    _load();
    SubtitleStore.changes.addListener(_onSubsChanged);
  }

  @override
  void dispose() {
    SubtitleStore.changes.removeListener(_onSubsChanged);
    _subsSoon?.cancel();
    super.dispose();
  }

  /// Subtitles being made save every few seconds: refresh the marks a
  /// little later, not on every save.
  void _onSubsChanged() {
    _subsSoon ??= Timer(const Duration(seconds: 5), () {
      _subsSoon = null;
      unawaited(_loadSubs());
    });
  }

  Future<void> _loadSubs() async {
    try {
      final marks = await SubtitleStore.pageMarks();
      if (mounted) setState(() => _subs = marks);
    } catch (_) {
      // No mark is better than no list.
    }
  }

  Future<void> _load() async {
    final all = await Bookmarks.load();
    final folders = await Bookmarks.folders();
    if (!mounted) return;
    setState(() {
      _all = all;
      _folders = folders;
    });
    unawaited(_loadSubs());
    // The list shows at once; pictures follow when their folder is known.
    if (_thumbs == null) {
      unawaited(
        Bookmarks.thumbDir().then((dir) {
          if (mounted && dir != null) setState(() => _thumbs = dir.path);
        }),
      );
    }
  }

  Future<void> _folderAction(String? from, {bool delete = false}) async {
    if (delete) {
      await Bookmarks.deleteFolder(from!);
    } else {
      final name = await _askName(
        context,
        from == null ? 'Thư mục mới' : 'Đổi tên thư mục',
        from ?? '',
      );
      if (name == null || name == from) return;
      final ok = from == null
          ? await Bookmarks.createFolder(name)
          : await Bookmarks.renameFolder(from, name);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tên thư mục trống hoặc đã có')),
        );
      }
    }
    await _load();
  }

  Future<void> _pageAction(Bookmark b, String action) async {
    switch (action) {
      case 'rename':
        final title = await _askName(context, 'Đổi tên trang', b.title);
        if (title != null) await Bookmarks.rename(b.url, title);
      case 'move':
        await editBookmark(context, b, editName: false);
      case 'remove':
        await Bookmarks.remove(b.url);
    }
    await _load();
  }

  Widget _picture(Bookmark b) {
    final dir = _thumbs;
    final file = b.thumb.isEmpty || dir == null
        ? null
        : File(p.join(dir, b.thumb));
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 64,
        height: 40,
        child: file != null && file.existsSync()
            ? Image.file(file, fit: BoxFit.cover, cacheWidth: 192)
            : const ColoredBox(
                color: Color(0x22FFC107),
                child: Icon(Icons.star, color: Colors.amber),
              ),
      ),
    );
  }

  Widget _page(Bookmark b) {
    final subs = _subs[SubtitleStore.pageKey(b.url)];
    return ListTile(
      leading: _picture(b),
      title: Text(
        b.title.isEmpty ? b.host : b.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: subs == null
          ? Text(b.host)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(b.host),
                const SizedBox(height: 2),
                SubsMark(subs),
              ],
            ),
      trailing: PopupMenuButton<String>(
        tooltip: 'Sửa trang',
        onSelected: (v) => _pageAction(b, v),
        itemBuilder: (_) => const [
          PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
          PopupMenuItem(value: 'move', child: Text('Chuyển vào thư mục…')),
          PopupMenuItem(value: 'remove', child: Text('Xoá')),
        ],
      ),
      onTap: () => widget.onOpen(b.url),
    );
  }

  @override
  Widget build(BuildContext context) {
    final shown = _all?.where((b) => b.matches(_filter)).toList() ?? [];
    final searching = _filter.trim().isNotEmpty;
    return RefreshIndicator(
      onRefresh: _load,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Trang đã lưu',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _folderAction(null),
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('Thư mục mới'),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Tìm tên, địa chỉ hoặc thư mục',
                prefixIcon: Icon(Icons.search),
              ),
              onChanged: (v) => setState(() => _filter = v),
            ),
          ),
          Expanded(
            child: _all == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      for (final folder in _folders)
                        if (!searching ||
                            folder.toLowerCase().contains(
                              _filter.trim().toLowerCase(),
                            ) ||
                            shown.any((b) => b.folder == folder)) ...[
                          ListTile(
                            leading: Icon(
                              searching || _expanded.contains(folder)
                                  ? Icons.folder_open
                                  : Icons.folder,
                            ),
                            title: Text(folder),
                            onTap: () => setState(() {
                              if (!_expanded.remove(folder)) {
                                _expanded.add(folder);
                              }
                            }),
                            trailing: PopupMenuButton<String>(
                              tooltip: 'Sửa thư mục',
                              onSelected: (v) =>
                                  _folderAction(folder, delete: v == 'delete'),
                              itemBuilder: (_) => const [
                                PopupMenuItem(
                                  value: 'rename',
                                  child: Text('Đổi tên'),
                                ),
                                PopupMenuItem(
                                  value: 'delete',
                                  child: Text('Xoá thư mục'),
                                ),
                              ],
                            ),
                          ),
                          if (searching || _expanded.contains(folder))
                            for (final b in shown.where(
                              (b) => b.folder == folder,
                            ))
                              _page(b),
                        ],
                      for (final b in shown.where((b) => b.folder.isEmpty))
                        _page(b),
                      if (shown.isEmpty &&
                          (_folders.isEmpty ||
                              searching &&
                                  !_folders.any(
                                    (f) => f.toLowerCase().contains(
                                      _filter.trim().toLowerCase(),
                                    ),
                                  )))
                        ListTile(
                          title: Text(
                            searching
                                ? 'Không tìm thấy trang'
                                : 'Chưa lưu trang nào',
                          ),
                        ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// "Có phụ đề · 45%": the page has subtitles (made or being made) in the
/// subtitle store.
class SubsMark extends StatelessWidget {
  const SubsMark(this.subs, {super.key});
  final PageSubs subs;

  @override
  Widget build(BuildContext context) {
    final color = subs.whole
        ? Colors.green
        : Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.closed_caption, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            subs.label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
