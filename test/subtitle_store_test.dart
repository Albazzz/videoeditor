import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/subtitle_store.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('subs_test');
    SubtitleStore.overrideDir = dir;
  });

  tearDown(() async {
    SubtitleStore.overrideDir = null;
    await dir.delete(recursive: true);
  });

  test('the same page always maps to the same entry', () {
    final a = SubtitleStore.idFor('https://phim.example.com/xem/tap-1#t=30');
    final b = SubtitleStore.idFor('https://phim.example.com/xem/tap-1');
    final c = SubtitleStore.idFor('https://phim.example.com/xem/tap-2');
    expect(a, b);
    expect(a, isNot(c));
  });

  test('saves, lists newest first, loads and deletes', () async {
    final older = SavedSubs(
      id: 'a',
      title: 'Tập 1',
      page: 'https://x.example/1',
      language: 'ja',
      updated: DateTime(2026, 1, 1),
      cues: const [Cue(start: 1, end: 2, text: 'Xin chào', source: 'こんにちは')],
      covered: const [(0, 120)],
    );
    final newer = SavedSubs(
      id: 'b',
      title: 'Tập 2',
      page: 'https://x.example/2',
      language: 'zh',
      updated: DateTime(2026, 2, 1),
      cues: const [Cue(start: 3, end: 4, text: 'Tạm biệt')],
      covered: const [],
    );
    await SubtitleStore.save(older);
    await SubtitleStore.save(newer);

    final all = await SubtitleStore.list();
    expect(all.map((s) => s.id), ['b', 'a']);

    final back = (await SubtitleStore.load('a'))!;
    expect(back.title, 'Tập 1');
    expect(back.cues.single.source, 'こんにちは');
    expect(back.covered.single, (0.0, 120.0));

    await SubtitleStore.delete('a');
    expect(await SubtitleStore.load('a'), isNull);
    expect((await SubtitleStore.list()).length, 1);
  });

  test('a damaged file is skipped instead of breaking the list', () async {
    final bad = await File('${dir.path}/subs/bad.json').create(recursive: true);
    bad.writeAsStringSync('{not json');
    expect(await SubtitleStore.list(), isEmpty);
  });
}
