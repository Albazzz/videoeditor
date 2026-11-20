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

  test('pages are marked with what the store holds for them', () async {
    const page = 'https://phim.example/xem/9';
    SavedSubs entry(String src, double until, {bool done = false}) => SavedSubs(
      id: SubtitleStore.idForVideo(page, src),
      title: 'Phim',
      page: '$page#t=5',
      source: src,
      language: 'ja',
      updated: DateTime(2026, 11, 19),
      cues: const [Cue(start: 1, end: 2, text: 'Chào', source: 'やあ')],
      covered: [(0, until)],
      duration: 1000,
      complete: done,
    );
    await SubtitleStore.save(entry('https://cdn.example/a.mp4', 250));
    var marks = await SubtitleStore.pageMarks();
    expect(marks[page]?.label, 'Có phụ đề · 25%');
    expect(marks[page]?.canResume, isTrue);
    await SubtitleStore.save(entry('https://cdn.example/b.mp4', 400));
    marks = await SubtitleStore.pageMarks();
    expect(marks[page]?.lines, 2);
    expect(marks[page]?.label, 'Có phụ đề · 40%');
    await SubtitleStore.delete(
      SubtitleStore.idForVideo(page, 'https://cdn.example/b.mp4'),
    );
    await SubtitleStore.delete(
      SubtitleStore.idForVideo(page, 'https://cdn.example/a.mp4'),
    );
    expect(await SubtitleStore.pageMarks(), isEmpty);
  });

  test('lists read small summaries, rebuilt when missing or out of date', () async {
    SavedSubs entry(String id, int lines, {String title = 'Phim'}) => SavedSubs(
      id: id,
      title: title,
      page: 'https://phim.example/$id',
      language: 'ja',
      updated: DateTime(2026, 11, lines),
      cues: [
        for (var i = 0; i < lines; i++)
          Cue(start: i * 2.0, end: i * 2.0 + 1, text: 'câu $i', source: 'x$i'),
      ],
      covered: const [(0, 100)],
      duration: 200,
    );
    await SubtitleStore.save(entry('a', 3));
    await SubtitleStore.save(entry('b', 5));
    var infos = await SubtitleStore.summaries();
    expect(infos.map((i) => (i.id, i.lines)), [('b', 5), ('a', 3)]);
    expect(infos.first.progress, 0.5);
    expect(infos.first.canResume, isTrue);
    // A summary lost (an older app version): made again from the entry.
    File('${dir.path}/subs/a.meta').deleteSync();
    await SubtitleStore.save(entry('b', 7, title: 'Phim mới'));
    infos = await SubtitleStore.summaries();
    expect(infos.map((i) => (i.id, i.lines, i.title)), [
      ('b', 7, 'Phim mới'),
      ('a', 3, 'Phim'),
    ]);
    await SubtitleStore.delete('b');
    expect((await SubtitleStore.summaries()).map((i) => i.id), ['a']);
    expect(File('${dir.path}/subs/b.meta').existsSync(), isFalse);
  });

  test('overlapping saves to one ID finish in order', () async {
    final item = SavedSubs(
      id: 'same',
      page: 'page',
      title: 'start',
      language: 'ja',
      updated: DateTime(2026),
      cues: [],
      covered: [],
    );
    await Future.wait([
      for (var i = 0; i < 12; i++)
        SubtitleStore.save(item.withTitle('Film $i')),
    ]);
    expect((await SubtitleStore.load('same'))?.title, 'Film 11');
  });
  test('a new signed video address keeps the subtitles of the film', () async {
    const page = 'https://phim.example/xem/1';
    const oldSrc = 'https://cdn.example/v.m3u8?hash=AAA&expires=1';
    const newSrc = 'https://cdn.example/v.m3u8?hash=BBB&expires=2';
    await SubtitleStore.save(
      SavedSubs(
        id: SubtitleStore.idForVideo(page, oldSrc),
        title: 'Phim',
        page: page,
        source: oldSrc,
        language: 'zh',
        updated: DateTime(2026, 11, 1),
        cues: const [Cue(start: 1, end: 2, text: 'Xin chào', source: '你好')],
        covered: const [(0, 600)],
        duration: 5400,
      ),
    );
    // Same page, same length, new address: found, moved, no duplicate.
    final found = await SubtitleStore.loadVideo(page, newSrc, duration: 5401);
    expect(found?.cues.single.text, 'Xin chào');
    expect(found?.source, newSrc);
    expect(found?.id, SubtitleStore.idForVideo(page, newSrc));
    expect((await SubtitleStore.list()).length, 1);
    // Another film on the page (other length) is not taken for it.
    expect(
      await SubtitleStore.loadVideo(
        page,
        'https://cdn.example/b.m3u8',
        duration: 1200,
      ),
      isNull,
    );
    // Entries saved per page before videos had their own key still match.
    const oldPage = 'https://phim.example/xem/2';
    await SubtitleStore.save(
      SavedSubs(
        id: SubtitleStore.idFor(oldPage),
        title: 'Cũ',
        page: oldPage,
        language: 'ja',
        updated: DateTime(2026, 10, 1),
        cues: const [Cue(start: 1, end: 2, text: 'Cũ')],
        covered: const [],
        duration: 3000,
      ),
    );
    final legacy = await SubtitleStore.loadVideo(
      oldPage,
      'https://cdn.example/c.mp4',
      duration: 3000,
    );
    expect(legacy?.cues.single.text, 'Cũ');
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

  test('entries are compressed and older plain files still load', () async {
    final cues = [
      for (var i = 0; i < 1500; i++)
        Cue(
          start: i * 3.123456,
          end: i * 3.123456 + 2.5,
          text: 'Câu phụ đề số $i, anh đi đâu vậy?',
          source: '第$i句，你去哪里？',
        ),
    ];
    final film = SavedSubs(
      id: 'film',
      title: 'Phim dài',
      page: 'https://x.example/film',
      language: 'zh',
      updated: DateTime(2026, 3, 1),
      cues: cues,
      covered: const [(0, 4700)],
    );
    await SubtitleStore.save(film);
    final stored = await SubtitleStore.storageBytes();
    final back = (await SubtitleStore.load('film'))!;
    expect(back.cues.length, 1500);
    expect(back.cues[10].start, closeTo(31.235, 0.0005));
    expect(back.cues[10].source, '第10句，你去哪里？');
    // About 160 KB as plain JSON.
    expect(stored, lessThan(60 * 1024));

    // A line not translated yet keeps its original after the round trip.
    await SubtitleStore.save(
      film.withCues(const [
        Cue(start: 1, end: 2, text: 'こんにちは', source: 'こんにちは'),
      ]),
    );
    expect((await SubtitleStore.load('film'))!.cues.single.source, 'こんにちは');

    File('${dir.path}/subs/old.json').writeAsStringSync(
      '{"id":"old","title":"Cũ","updated":0,'
      '"cues":[[1,2,"Xin chào","こんにちは"]]}',
    );
    expect((await SubtitleStore.load('old'))!.cues.single.text, 'Xin chào');
    expect((await SubtitleStore.list()).map((s) => s.id), contains('old'));
    await SubtitleStore.delete('old');
    expect(File('${dir.path}/subs/old.json').existsSync(), isFalse);
  });

  test('renaming keeps the lines; untranslated ones are counted', () async {
    final s = SavedSubs(
      id: 'r',
      title: 'tên cũ',
      page: 'https://x.example/r',
      language: 'ja',
      updated: DateTime(2026, 1, 1),
      cues: const [
        Cue(start: 1, end: 2, text: 'Xin chào', source: 'こんにちは'),
        Cue(start: 3, end: 4, text: 'ありがとう', source: 'ありがとう'),
      ],
      covered: const [(0, 10)],
    );
    expect(s.untranslated, 1);
    await SubtitleStore.save(s.withTitle('Tập 1 - bản đẹp'));
    final back = (await SubtitleStore.load('r'))!;
    expect(back.title, 'Tập 1 - bản đẹp');
    expect(back.cues.length, 2);
    expect(back.covered.single, (0.0, 10.0));
  });

  test('a damaged file is skipped instead of breaking the list', () async {
    final bad = await File('${dir.path}/subs/bad.json').create(recursive: true);
    bad.writeAsStringSync('{not json');
    expect(await SubtitleStore.list(), isEmpty);
  });

  test('ranges merge and measure what was listened to', () {
    final r = mergeRanges([(100, 200), (0, 50), (49.5, 90), (190, 210)]);
    expect(r, [(0.0, 90.0), (100.0, 210.0)]);
    expect(coveredSeconds([(0, 50), (40, 60)]), 60);
    expect(coveredSeconds([]), 0);
  });

  test('whole video needs one range from the start to near the end', () {
    expect(coversWholeVideo([(0, 1395)], 1400), isTrue);
    expect(coversWholeVideo([(0, 700), (700.5, 1400)], 1400), isTrue);
    expect(coversWholeVideo([(0, 700), (800, 1400)], 1400), isFalse);
    expect(coversWholeVideo([(30, 1400)], 1400), isFalse);
    expect(coversWholeVideo([(0, 600)], 0), isFalse);
    expect(coversWholeVideo([(0, 600)], 0, reachedEnd: true), isTrue);
  });

  test('progress and completeness survive a save', () async {
    final subs = SavedSubs(
      id: 'p',
      title: 't',
      page: 'https://x.example/p',
      language: 'ja',
      updated: DateTime(2026, 3, 1),
      cues: const [Cue(start: 1, end: 2, text: 'a')],
      covered: const [(0, 300)],
      duration: 1200,
    );
    await SubtitleStore.save(subs);
    final back = (await SubtitleStore.load('p'))!;
    expect(back.duration, 1200);
    expect(back.complete, isFalse);
    expect(back.progress, closeTo(0.25, 0.001));
    expect(back.isWholeVideo, isFalse);

    final old = SavedSubs.fromJson({'id': 'o', 'cues': [], 'covered': []});
    expect(old.duration, 0);
    expect(old.progress, isNull);
  });
}
