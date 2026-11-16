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

class _BookmarksSheet extends StatefulWidget {
  const _BookmarksSheet();

  @override
  State<_BookmarksSheet> createState() => _BookmarksSheetState();
}

class _BookmarksSheetState extends State<_BookmarksSheet> {
  List<Bookmark>? _all;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await Bookmarks.load();
    if (mounted) setState(() => _all = all);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final all = _all;
    final words = _filter.toLowerCase().split(' ').where((w) => w.isNotEmpty);
    final shown = all == null
        ? const <Bookmark>[]
        : all.where((b) {
            final have = '${b.title} ${b.url}'.toLowerCase();
            return words.every(have.contains);
          }).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Trang đã lưu', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'Tìm theo tên hoặc địa chỉ',
                    prefixIcon: Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: all == null
                ? const Center(child: CircularProgressIndicator())
                : all.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Chưa lưu trang nào.\nMở một trang rồi bấm ⋮ → '
                        'Lưu trang này.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final b = shown[i];
                      return ListTile(
                        leading: const Icon(Icons.star, color: Colors.amber),
                        title: Text(
                          b.title.isEmpty ? b.host : b.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          b.host,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          tooltip: 'Bỏ lưu',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await Bookmarks.remove(b.url);
                            await _load();
                          },
                        ),
                        onTap: () => Navigator.pop(context, b.url),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
