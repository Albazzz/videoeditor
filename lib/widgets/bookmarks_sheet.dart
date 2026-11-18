import 'package:flutter/material.dart';

import '../services/bookmarks.dart';

/// The saved pages; returns the address to open, or null.
Future<String?> showBookmarks(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _BookmarksSheet(),
    );

String _folderName(String folder) => folder.isEmpty ? 'Ngoài cùng' : folder;

Future<String?> _askName(
  BuildContext context,
  String label, [
  String name = '',
]) {
  var value = name;
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(label),
      content: TextFormField(
        initialValue: name,
        autofocus: true,
        onChanged: (v) => value = v,
        onFieldSubmitted: (v) => Navigator.pop(ctx, v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, value.trim()),
          child: const Text('Lưu'),
        ),
      ],
    ),
  );
}

/// Also used by the action immediately after a page is saved.
Future<void> editBookmark(
  BuildContext context,
  Bookmark bookmark, {
  bool editName = true,
}) async {
  final folders = await Bookmarks.folders();
  if (!context.mounted) return;
  var folder = folders.contains(bookmark.folder) ? bookmark.folder : '';
  var title = bookmark.title;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(editName ? 'Sửa trang đã lưu' : 'Chuyển vào thư mục'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (editName)
            TextFormField(
              initialValue: title,
              decoration: const InputDecoration(labelText: 'Tên trang'),
              onChanged: (v) => title = v,
            ),
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
      title: editName ? title : null,
      folder: folder,
    );
  }
}

class _BookmarksSheet extends StatefulWidget {
  const _BookmarksSheet();
  @override
  State<_BookmarksSheet> createState() => _BookmarksSheetState();
}

class _BookmarksSheetState extends State<_BookmarksSheet> {
  List<Bookmark>? _all;
  List<String> _folders = [];
  final _expanded = <String>{};
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Bookmarks.load();
    final folders = await Bookmarks.folders();
    if (mounted) {
      setState(() {
        _all = all;
        _folders = folders;
      });
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

  Widget _page(Bookmark b) => ListTile(
    leading: const Icon(Icons.star, color: Colors.amber),
    title: Text(
      b.title.isEmpty ? b.host : b.title,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
    ),
    subtitle: Text(b.host),
    trailing: PopupMenuButton<String>(
      tooltip: 'Sửa trang',
      onSelected: (v) => _pageAction(b, v),
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'rename', child: Text('Đổi tên')),
        PopupMenuItem(value: 'move', child: Text('Chuyển vào thư mục…')),
        PopupMenuItem(value: 'remove', child: Text('Xoá')),
      ],
    ),
    onTap: () => Navigator.pop(context, b.url),
  );

  @override
  Widget build(BuildContext context) {
    final shown = _all?.where((b) => b.matches(_filter)).toList() ?? [];
    final searching = _filter.trim().isNotEmpty;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
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
                                onSelected: (v) => _folderAction(
                                  folder,
                                  delete: v == 'delete',
                                ),
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
      ),
    );
  }
}
