import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/widgets/subtitle_picker.dart';

SavedSubs entry(String id, String title, int day) => SavedSubs(
  id: id,
  title: title,
  page: 'https://$id.example/xem',
  language: 'zh',
  updated: DateTime(2026, 1, day),
  cues: const [],
  covered: const [],
);

void main() {
  test('the same film on another site comes first, then the newest', () {
    final all = [
      entry('a', 'Phim khác hẳn - Tập 3', 20),
      entry('b', 'Trường Nguyệt Tẫn Minh Tập 12 Vietsub', 2),
      entry('c', 'Một phim mới xem', 25),
    ];
    final ranked = rankByTitle(
      all,
      'Xem Trường Nguyệt Tẫn Minh - Tập 12 | PhimHay',
    );
    // Shared site words (xem, tập) do not count, so the rest go newest first.
    expect(ranked.map((s) => s.id), ['b', 'c', 'a']);
    expect(rankByTitle(all, '').map((s) => s.id), ['c', 'a', 'b']);
  });

  test('title words ignore case, punctuation, site words and one letter', () {
    expect(titleWords('Xem Tập 12 | A-B: Trường! Vietsub'), {'12', 'trường'});
  });
}
