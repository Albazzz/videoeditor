import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/asr_worker.dart';
import 'package:video/services/audio_feed.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/video_pipeline.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/services/translator.dart';

class _Worker implements AsrWorker {
  final controller = StreamController<AsrEvent>.broadcast(sync: true);
  @override
  Stream<AsrEvent> get events => controller.stream;
  late int gen;
  late double base;
  bool stopped = false;
  @override
  void reset(int gen, double baseSec) {
    this.gen = gen;
    base = baseSec;
  }

  @override
  void feed(int gen, String wavPath, {bool last = false}) {}
  @override
  Future<void> dispose() async {
    stopped = true;
    await Future<void>.microtask(controller.close);
  }
}

class _Feed extends AudioFeed {
  double? startAt, length;
  @override
  Future<void> start({
    required String input,
    required String outDir,
    Map<String, String> headers = const {},
    double startSec = 0,
    double? lengthSec,
    bool hls = false,
  }) async {
    startAt = startSec;
    length = lengthSec;
  }
}

class _Translator extends PassthroughTranslator {
  TranslatorStatus value = const TranslatorStatus(TranslationState.ready);
  final ready = Completer<void>();
  final translated = <(String, String)>[];
  @override
  TranslatorStatus get status => value;
  @override
  Future<void> prepare(String lang) => ready.future;
  @override
  Future<String> translate(String text, String lang) async {
    translated.add((text, lang));
    return 'VI $text';
  }
}

Future<void> _until(bool Function() condition) async {
  final limit = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(limit)) fail('Hết thời gian chờ');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('disjoint reservations favour the viewer and split only a long gap', () {
    List<(double, double)> plan(
      double at, {
      List<(double, double)> have = const [],
      int slots = 2,
    }) => planRuns(covered: have, duration: 300, position: at, slots: slots);
    expect(plan(0), [(0.0, 150.0), (150.0, 300.0)]);
    expect(plan(90), [(90.0, 300.0), (0.0, 90.0)]);
    expect(plan(10, have: [(0, 100)]), [(100.0, 200.0), (200.0, 300.0)]);
    expect(plan(0, have: [(0, 100), (120, 300)]), [(100.0, 120.0)]);
    expect(plan(120, slots: 1), [(120.0, 300.0)]);
    expect(plan(0, have: [(0, 300)]), isEmpty);
  });

  late Directory root;
  final workers = <_Worker>[], feeds = <_Feed>[];
  final languages = <String>[];
  late SubtitleSession session;
  SubtitleSession create({
    SubtitleMode mode = SubtitleMode.whole,
    SavedSubs? saved,
    Translator? translator,
  }) => SubtitleSession(
    input: 'film.mp4',
    language: 'ja',
    saved: saved,
    translator: translator,
    mode: mode,
    temporaryDirectory: () async => root,
    retainedAudio: RetainedAudioStore(
      baseDirectory: () async => Directory('${root.path}/audio'),
    ),
    createFeed: () {
      final f = _Feed();
      feeds.add(f);
      return f;
    },
    createWorker: (lang) async {
      languages.add(lang);
      final w = _Worker();
      workers.add(w);
      return w;
    },
  );
  group('session scheduling', () {
    setUp(() async {
      // Memory pressure in one test must not leave one recogniser for the next.
      VideoPipeline.recognizers.capacity = 2;
      workers.clear();
      feeds.clear();
      languages.clear();
      root = await Directory.systemTemp.createTemp('vsub_test');
    });
    tearDown(() async {
      session.dispose();
      await _until(
        () =>
            workers.every((w) => w.stopped) &&
            Directory('${root.path}/vsub').listSync().isEmpty,
      );
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'saved language, coverage and text are used before model download completes',
      () async {
        final translator = _Translator()
          ..value = const TranslatorStatus(TranslationState.downloading);
        final saved = SavedSubs(
          id: 'a',
          title: 'A',
          page: 'a',
          language: 'ko',
          updated: DateTime(2026),
          cues: [Cue(start: 1, end: 3, text: '안녕', source: '안녕')],
          covered: [(0, 60)],
          duration: 100,
        );
        session = create(saved: saved, translator: translator)..duration = 100;
        await session.start(0);
        await _until(() => feeds.isNotEmpty);
        expect(languages, ['ko']);
        expect(feeds.single.startAt, 60);
        expect(session.covered, [(0.0, 60.0)]);
        expect(session.cues.single.text, '안녕');
        expect(session.steps[2].detail, contains('tải gói dịch'));
        expect(session.steps.last.state, StageState.active);
        expect(session.steps.last.detail, contains('1 câu chờ bộ dịch'));
        translator.value = const TranslatorStatus(TranslationState.ready);
        translator.ready.complete();
        await _until(() => session.cues.single.text == 'VI 안녕');
        expect(translator.translated, [('안녕', 'ko')]);
      },
    );

    test(
      'both timelines merge, memory pressure releases worker 2, remaining gaps finish',
      () async {
        session = create()..duration = 300;
        await session.start(100);
        await _until(() => feeds.length == 2);
        expect(
          feeds.map((f) => (f.startAt, f.length)),
          unorderedEquals([(100.0, 200.0), (0.0, 102.0)]),
        );
        final primary = workers.singleWhere((w) => w.base == 100),
            second = workers.singleWhere((w) => w.base == 0);
        primary.controller.add(AsrProgress(primary.gen, 140, false));
        second.controller.add(AsrProgress(second.gen, 25, false));
        second.controller.add(AsrSegment(second.gen, 12, 13, 'World', 'en'));
        primary.controller.add(
          AsrSegment(primary.gen, 112, 113, 'Hello', 'en'),
        );
        expect(session.cues.map((c) => c.start), [12.0, 112.0]);
        expect(session.covered, [(0.0, 25.0), (100.0, 140.0)]);
        expect(session.stage, contains('Lượt 2'));
        session.didHaveMemoryPressure();
        expect(second.stopped, true);
        expect(primary.stopped, false);
        expect(session.stage, isNot(contains('Lượt 2')));
        primary.controller.add(AsrProgress(primary.gen, 300, true));
        await _until(() => feeds.length == 3);
        expect(feeds.last.startAt, 25);
        expect(feeds.last.length, 77);
        final last = workers.last;
        last.controller.add(AsrProgress(last.gen, 102, true));
        expect(session.finished, true);
        expect(session.covered, [(0.0, 300.0)]);
      },
    );

    test(
      'a settled seek replans both runs, follow mode uses one worker',
      () async {
        session = create()..duration = 300;
        await session.start(0);
        await _until(() => feeds.length == 2);
        final old = List.of(workers);
        for (var i = 0; i < 3; i++) {
          session.updatePosition(230);
        }
        await _until(() => feeds.length == 4);
        expect(old.every((w) => w.stopped), true);
        expect(
          feeds.skip(2).map((f) => f.startAt),
          unorderedEquals([230.0, 0.0]),
        );
        expect(session.stage, contains('Lượt 1: 3:50'));
        session.mode = SubtitleMode.follow;
        await _until(() => feeds.length == 5);
        expect(workers.where((w) => !w.stopped).length, 1);
        expect(feeds.last.startAt, 230);
      },
    );
  });

  test(
    'the same summary and steps explain translation waits and account failures',
    () {
      final t = _Translator();
      final s = SubtitleSession(
        input: 'film.mp4',
        language: 'ja',
        translator: t,
      );
      addTearDown(s.dispose);
      for (final (status, expected, state) in [
        (
          const TranslatorStatus(TranslationState.gathering, queued: 3),
          'gom 3 câu',
          StageState.active,
        ),
        (
          TranslatorStatus(
            TranslationState.cooldown,
            inFlight: 1,
            cooldownUntil: DateTime.now().add(const Duration(seconds: 12)),
            note: 'Vercel',
          ),
          'giới hạn tần suất',
          StageState.active,
        ),
        (
          const TranslatorStatus(
            TranslationState.unavailable,
            note: 'Tài khoản hết tiền',
          ),
          'hết tiền',
          StageState.failed,
        ),
        (
          const TranslatorStatus(TranslationState.downloading),
          'tải gói dịch',
          StageState.waiting,
        ),
      ]) {
        t.value = status;
        expect(s.stage, contains(expected));
        expect(s.steps.last.detail, contains(expected));
        expect(s.steps.last.state, state);
      }
    },
  );
}
