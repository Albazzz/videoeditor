import 'package:flutter/material.dart';

import '../models/subtitle_file.dart';
import '../services/subtitle_store.dart';
import 'common.dart';

/// What to do with subtitles taken from the store for another page.
enum PickedUse { watch, carryOn }

/// Words every film site puts in its titles; they say nothing about which
/// film it is.
const _siteWords = {
  'xem',
  'phim',
  'tập',
  'tap',
  'vietsub',
  'thuyết',
  'full',
  'hd',
  'online',
  'ep',
  'episode',
  'mới',
  'hay',
  'nhất',
  'free',
  'watch',
  'sub',
  'engsub',
};

/// Words of a title, for matching the same film on another site.
Set<String> titleWords(String title) => {
  for (final w in title.toLowerCase().split(
    RegExp(r'[^\p{L}\p{N}]+', unicode: true),
  ))
    if (w.length >= 2 && !_siteWords.contains(w)) w,
};

/// Saved entries, those whose titles share most words with [title] first,
/// then the newest.
List<SavedSubs> rankByTitle(List<SavedSubs> all, String title) {
  final want = titleWords(title);
  int score(SavedSubs s) => titleWords(s.title).intersection(want).length;
  return List.of(all)..sort((a, b) {
    final byScore = score(b).compareTo(score(a));
    return byScore != 0 ? byScore : b.updated.compareTo(a.updated);
  });
}

/// Lets the user take subtitles from the store: the ones this video
/// already has ([currentId], listed first) or those saved for another page
/// (the same film on another site). Nothing is left out. Returns the entry
/// and what to do with it.
Future<(SavedSubs, PickedUse)?> pickSavedSubtitles(
  BuildContext context, {
  required String currentId,
  required String pageTitle,
  required double duration,
  required bool canCarryOn,
}) async {
  final all = await SubtitleStore.list();
  if (!context.mounted) return null;
  if (all.isEmpty) {
    toast(context, 'Kho phụ đề chưa có phụ đề nào');
    return null;
  }
  final ranked = rankByTitle(all, pageTitle);
  final current = ranked.where((s) => s.id == currentId).toList();
  final picked = await showModalBottomSheet<SavedSubs>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _PickerSheet(
      entries: [...current, ...ranked.where((s) => s.id != currentId)],
      currentId: currentId,
      duration: duration,
    ),
  );
  if (picked == null || !context.mounted) return null;
  final unfinished = picked.canResume;
  if (!canCarryOn || !unfinished) return (picked, PickedUse.watch);
  final use = await showDialog<PickedUse>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(picked.title.isEmpty ? 'Phụ đề đã chọn' : picked.title),
      content: Text(
        'Phụ đề này mới ${subtitleProgressLabel(covered: picked.covered, duration: picked.duration).toLowerCase()}. '
        'Xem với những dòng đã có, hay để app làm tiếp phần còn thiếu '
        'trên trang này?',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, PickedUse.watch),
          child: const Text('Chỉ xem'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, PickedUse.carryOn),
          child: const Text('Làm tiếp'),
        ),
      ],
    ),
  );
  return use == null ? null : (picked, use);
}

class _PickerSheet extends StatefulWidget {
  const _PickerSheet({
    required this.entries,
    required this.duration,
    this.currentId = '',
  });
  final List<SavedSubs> entries;
  final double duration;
  final String currentId;

  @override
  State<_PickerSheet> createState() => _PickerSheetState();
}

class _PickerSheetState extends State<_PickerSheet> {
  String _filter = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final words = titleWords(_filter);
    final shown = words.isEmpty
        ? widget.entries
        : widget.entries.where((s) {
            final have = '${s.title} ${s.page}'.toLowerCase();
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
                Text('Dùng phụ đề từ kho', style: theme.textTheme.titleMedium),
                const SizedBox(height: 2),
                Text(
                  'Mọi phụ đề trong kho, cả phụ đề video này đang có. Cùng '
                  'phim ở trang khác? Chọn để xem tiếp trên trang này.',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                ClearableField(
                  controller: _search,
                  hint: 'Tìm theo tên phim',
                  prefixIcon: const Icon(Icons.search),
                  onChanged: (v) => setState(() => _filter = v),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: shown.length,
              itemBuilder: (context, i) {
                final s = shown[i];
                final host = Uri.tryParse(s.page)?.host ?? s.page;
                final label = s.imported
                    ? 'Từ file · ${kSubtitleLanguages[s.language] ?? s.language}'
                    : subtitleProgressLabel(
                        covered: s.covered,
                        duration: s.duration,
                        reachedEnd: s.complete,
                      );
                // Another cut of the film (or another episode) runs longer
                // or shorter; the lines would not line up.
                final mismatch =
                    widget.duration > 0 &&
                    s.duration > 0 &&
                    (widget.duration - s.duration).abs() > 90;
                final mine = s.id == widget.currentId;
                return ListTile(
                  leading: Icon(
                    mine ? Icons.check_circle : Icons.closed_caption_outlined,
                    color: mine ? theme.colorScheme.primary : null,
                  ),
                  title: Text(
                    s.title.isEmpty ? host : s.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (mine)
                        Text(
                          'Đang gắn với video này',
                          style: TextStyle(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      Text(
                        '$host · $label · '
                        '${s.cues.isEmpty ? 'chưa có dòng nào' : '${s.cues.length} dòng'}',
                      ),
                      if (mismatch)
                        Text(
                          'Dài ${formatTime(s.duration)}, video này '
                          '${formatTime(widget.duration)}: có thể không khớp',
                          style: const TextStyle(color: Colors.orange),
                        ),
                    ],
                  ),
                  // Listed so nothing seems lost, but there is nothing
                  // to show yet.
                  enabled: s.cues.isNotEmpty,
                  onTap: () => Navigator.pop(context, s),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
