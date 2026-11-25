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
import 'support/pcm_audio.dart';

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
    await writeAudioChunks(outDir, lengthSec ?? 300);
    done = true;
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
      await session.closeAudio();
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
        await _until(() => workers.isNotEmpty);
        expect(languages, ['ko']);
        expect(feeds.single.startAt, 0);
        expect(feeds.single.length, 100);
        expect(session.audioAvailability.complete, true);
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
        await _until(() => workers.length == 2);
        expect(feeds.map((f) => (f.startAt, f.length)), [(0.0, 300.0)]);
        final primary = workers.singleWhere((w) => w.base == 98),
            second = workers.singleWhere((w) => w.base == 0);
        primary.controller.add(AsrProgress(primary.gen, 140, false));
        second.controller.add(AsrProgress(second.gen, 25, false));
        second.controller.add(AsrSegment(second.gen, 12, 13, 'World', 'en'));
        primary.controller.add(
          AsrSegment(primary.gen, 112, 113, 'Hello', 'en'),
        );
        expect(session.cues.map((c) => c.start), [12.0, 112.0]);
        expect(session.covered, [(0.0, 25.0), (98.0, 140.0)]);
        expect(session.stage, contains('Lượt 2'));
        session.didHaveMemoryPressure();
        expect(second.stopped, true);
        expect(primary.stopped, false);
        expect(session.stage, isNot(contains('Lượt 2')));
        primary.controller.add(AsrProgress(primary.gen, 300, true));
        await _until(() => workers.length == 3);
        expect(feeds, hasLength(1));
        expect(workers.last.base, 18);
        final last = workers.last;
        last.controller.add(AsrProgress(last.gen, 98, true));
        expect(session.finished, true);
        expect(session.covered, [(0.0, 300.0)]);
      },
    );

    test(
      'a settled seek replans both runs, follow mode uses one worker',
      () async {
        session = create()..duration = 300;
        await session.start(0);
        await _until(() => workers.length == 2);
        final old = List.of(workers);
        for (var i = 0; i < 3; i++) {
          session.updatePosition(230);
        }
        await _until(() => workers.length == 4);
        expect(old.every((w) => w.stopped), true);
        expect(
          workers.skip(2).map((w) => w.base),
          unorderedEquals([228.0, 0.0]),
        );
        expect(session.stage, contains('Lượt 1: 3:48'));
        session.mode = SubtitleMode.follow;
        await _until(() => workers.length == 5);
        expect(workers.where((w) => !w.stopped).length, 1);
        expect(workers.last.base, 228);
        expect(feeds, hasLength(1));
      },
    );

    test(
      'retry recovers an initialization failure without recreating the session',
      () async {
        var attempts = 0;
        session = SubtitleSession(
          input: 'film.mp4',
          language: 'ja',
          parallel: false,
          temporaryDirectory: () async {
            if (++attempts == 1) {
              throw const FileSystemException('temporary unavailable');
            }
            return root;
          },
          retainedAudio: RetainedAudioStore(
            baseDirectory: () async => Directory('${root.path}/audio'),
          ),
          createFeed: () {
            final feed = _Feed();
            feeds.add(feed);
            return feed;
          },
          createWorker: (_) async {
            final worker = _Worker();
            workers.add(worker);
            return worker;
          },
        )..duration = 100;
        await session.start(0);
        expect(session.canRetry, true);
        await session.retry();
        await _until(() => feeds.length == 1);
        expect(attempts, 2);
        expect(session.error, isNull);
        expect(session.canRetry, false);
      },
    );

    test(
      'retry resumes missing audio and keeps completed cues and coverage',
      () async {
        session = create()..duration = 300;
        await session.start(0);
        await _until(() => workers.length == 2);
        final old = List.of(workers);
        final first = workers.singleWhere((w) => w.base == 0);
        first.controller.add(AsrSegment(first.gen, 10, 11, 'Hello', 'ja'));
        first.controller.add(AsrProgress(first.gen, 40, false));
        first.controller.add(AsrError(first.gen, 'connection lost'));
        expect(session.canRetry, true);
        expect(session.covered, [(0.0, 40.0)]);
        final kept = List.of(session.cues);
        await Future.wait([session.retry(), session.retry()]);
        await _until(() => workers.length == 4);
        expect(session.error, isNull);
        expect(session.canRetry, false);
        expect(old.every((w) => w.stopped), true);
        expect(session.cues, kept);
        expect(session.covered, [(0.0, 40.0)]);
        expect(
          workers.skip(2).map((w) => w.base),
          unorderedEquals([38.0, 168.0]),
        );
        session.requestStop();
        await session.retry();
        expect(feeds, hasLength(1));
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
