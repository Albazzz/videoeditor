import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';
import 'player_screen.dart';

/// Asks for the vault key and checks it. Returns true when it is correct.
Future<bool> unlockVault(BuildContext context) async {
  final key = await askKey(context, 'Nhập key kho ẩn');
  if (key == null) return false;
  final ok = await keyStore.verifyVault(key);
  if (!ok && context.mounted) toast(context, 'Sai key');
  return ok;
}

/// Imported videos. With [hidden] it shows the vault instead; the caller
/// must have checked the vault key first.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, this.hidden = false});
  final bool hidden;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<VideoItem>? _items;
  bool _importing = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await VideoLibrary.list(hidden: widget.hidden);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _import() async {
    final picked = await FilePicker.pickFiles(type: FileType.video);
    final path = picked.isEmpty ? null : picked.first.path;
    if (path == null) return;
    setState(() => _importing = true);
    try {
      await VideoLibrary.import(path);
    } catch (e) {
      if (mounted) toast(context, 'Không thêm được video: $e');
    }
    if (mounted) setState(() => _importing = false);
    await _reload();
  }

  Future<void> _play(VideoItem item) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(title: item.name, item: item),
      ),
    );
    // Exporting may have added a file.
    await _reload();
  }

  Future<void> _setHidden(VideoItem item, bool hidden) async {
    // Hiding also needs the key, so nobody can bury a video by accident.
    if (hidden && !await unlockVault(context)) return;
    await VideoLibrary.setHidden(item, hidden);
    if (mounted) toast(context, hidden ? 'Đã chuyển vào kho ẩn' : 'Đã bỏ ẩn');
    await _reload();
  }

  Future<void> _delete(VideoItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá video?'),
        content: Text('"${item.name}" sẽ bị xoá khỏi app.'),
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
    );
    if (ok != true) return;
    await VideoLibrary.delete(item);
    await _reload();
  }

  Future<void> _openVault() async {
    if (!await unlockVault(context) || !mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const LibraryScreen(hidden: true)),
    );
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.hidden ? 'Kho ẩn' : 'Thư viện'),
        actions: [
          if (!widget.hidden)
            IconButton(
              tooltip: 'Kho ẩn',
              icon: const Icon(Icons.lock_outline),
              onPressed: _openVault,
            ),
        ],
      ),
      floatingActionButton: widget.hidden
          ? null
          : FloatingActionButton.extended(
              onPressed: _importing ? null : _import,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add),
              label: Text(_importing ? 'Đang thêm…' : 'Thêm video'),
            ),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : items.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  widget.hidden
                      ? 'Kho ẩn đang trống.\nChọn "Ẩn" ở một video trong Thư viện để đưa vào đây.'
                      : 'Chưa có video nào.\nBấm "Thêm video" để lấy từ máy.',
                  textAlign: TextAlign.center,
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: items.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final item = items[i];
                final mb = item.file.lengthSync() / 1e6;
                return ListTile(
                  leading: const Icon(Icons.movie_outlined),
                  title: Text(
                    item.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Text(
                    '${mb.toStringAsFixed(1)} MB'
                    '${item.srtFile.existsSync() ? ' · có phụ đề' : ''}',
                  ),
                  onTap: () => _play(item),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => switch (v) {
                      'hide' => _setHidden(item, !widget.hidden),
                      _ => _delete(item),
                    },
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'hide',
                        child: Text(widget.hidden ? 'Bỏ ẩn' : 'Ẩn'),
                      ),
                      const PopupMenuItem(value: 'delete', child: Text('Xoá')),
                    ],
                  ),
                );
              },
            ),
    );
  }
}
