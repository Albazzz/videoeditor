import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/active_work.dart';
import 'package:video/services/asr_worker.dart';
import 'package:video/services/audio_feed.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_revision.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/services/translator.dart';
import 'package:video/services/video_language.dart';
import 'package:video/services/video_library.dart';
import 'package:video/services/video_pipeline.dart';

const _old = Cue(start: 2, end: 4, text: 'Cũ', source: 'Original');

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _Translator extends PassthroughTranslator {
  final calls = <(String, String)>[];
  Completer<String>? pending;
  @override
  TranslatorStatus get status => const TranslatorStatus(TranslationState.ready);
  @override
  Future<String> translate(String text, String lang) {
    calls.add((text, lang));
    return pending?.future ?? Future.value('VI $text');
  }

  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int)? onProgress,
  }) async {
    final result = <String?>[];
    for (final line in lines) {
      result.add(await translate(line, lang));
      onProgress?.call(result.length);
    }
    return result;
  }
}

class _Worker implements AsrWorker {
  final eventsController = StreamController<AsrEvent>.broadcast(sync: true);
  late int gen;
  @override
  Stream<AsrEvent> get events => eventsController.stream;
  @override
  void reset(int gen, double baseSec) {
    this.gen = gen;
  }

  @override
  void feed(int gen, String wavPath, {bool last = false}) {}
  @override
  Future<void> dispose() async {
    await Future<void>.microtask(eventsController.close);
  }
}

class _Feed extends AudioFeed {
  @override
  Future<void> start({
    required String input,
    required String outDir,
    Map<String, String> headers = const {},
    double startSec = 0,
    double? lengthSec,
    bool hls = false,
  }) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('language needs several speech samples and stays locked', () {
    final language = VideoLanguage('auto');
    expect(language.observe('', 8), isFalse);
    expect(language.code, 'auto');
    expect(language.observe('<|ja|>', 2), isFalse);
    expect(language.observe('ja', 2), isFalse);
    expect(language.observe('japanese', 2), isTrue);
    expect(language.code, 'ja');
    expect(language.observe('zh', 8), isFalse);
    expect(language.code, 'ja');
    language.select('ko');
    expect(language.code, 'ko');
    language.select('auto');
    expect(language.locked, isFalse);
  });

  test('conflicting recognition and silence never default to Japanese', () {
    final language = VideoLanguage('auto');
    for (var i = 0; i < 3; i++) {
      language.observe('ja', 2);
      language.observe('zh', 2);
      language.observe('unknown', 4);
      language.observe('ko', .1);
    }
    expect(language.code, 'auto');
  });

  test(
    'ready videos share a stage; later stages progress independently',
    () async {
      final stage1 = PipelineStage(1), stage2 = PipelineStage(1);
      final releaseA = await stage1.acquire('A');
      final order = <String>[];
      final a2 = stage1.run('A', () async => order.add('A2'));
      final b1 = stage1.run('B', () async => order.add('B1'));
      final c1 = stage1.run('C', () async => order.add('C1'));
      await stage2.run('A', () async => order.add('A-next-stage'));
      expect(order, ['A-next-stage']);
      releaseA();
      await Future.wait([a2, b1, c1]);
      expect(order, ['A-next-stage', 'B1', 'A2', 'C1']);
    },
  );

  test('stage capacity is bounded and errors release their slot', () async {
    final stage = PipelineStage(2);
    var running = 0, peak = 0;
    await Future.wait([
      for (var i = 0; i < 8; i++)
        stage.run('$i', () async {
          running++;
          if (running > peak) peak = running;
          await Future<void>.delayed(const Duration(milliseconds: 5));
          running--;
        }),
    ]);
    expect(peak, 2);
    await expectLater(
      stage.run('bad', () async => throw StateError('bad')),
      throwsStateError,
    );
    expect(await stage.run('good', () async => 1), 1);
  });

  test(
    'cancelled queued work leaves the pipeline without waiting for a film to finish',
    () async {
      final stage = PipelineStage(1);
      final releaseA = await stage.acquire('A');
      final cancelled = Completer<void>();
      final waiting = stage.acquire('B', cancelled: cancelled.future);
      cancelled.complete();
      final releaseCancelled = await waiting;
      releaseCancelled();
      var ranC = false;
      final c = stage.run('C', () async => ranC = true);
      await Future<void>.delayed(Duration.zero);
      expect(ranC, isFalse);
      releaseA();
      await c;
      expect(ranC, isTrue);
    },
  );

  test(
    'revisions preserve timing/source, merge appended cues and undo safely',
    () async {
      const later = Cue(start: 8, end: 9, text: 'later', source: 'later');
      final translator = _Translator();
      final draft = await CueRevision.generate(
        videoId: 'A',
        cues: [_old],
        indices: [0],
        language: 'en',
        translator: translator,
      );
      final next = draft.apply('A', [_old, later]);
      expect(next.first.text, 'VI Original');
      expect(next.first.source, 'Original');
      expect((next.first.start, next.first.end), (2.0, 4.0));
      expect(next.last, same(later));
      expect(draft.apply('A', next, undo: true).first, same(_old));
      expect(() => draft.apply('B', [_old]), throwsStateError);
      expect(
        () => draft.apply('A', [
          const Cue(start: 2, end: 4, text: 'edited', source: 'Original'),
        ]),
        throwsStateError,
      );
      expect(translator.calls, [('Original', 'en')]);
    },
  );

  test('revision without source leaves the old subtitles untouched', () async {
    const cue = Cue(start: 1, end: 2, text: 'old');
    await expectLater(
      CueRevision.generate(
        videoId: 'A',
        cues: [cue],
        indices: [0],
        language: 'en',
        translator: _Translator(),
      ),
      throwsStateError,
    );
    expect(cue.text, 'old');
  });

  group('storage and ownership', () {
    late Directory dir;
    setUp(() async {
      dir = await Directory.systemTemp.createTemp('video_pipeline_');
      SubtitleStore.overrideDir = dir;
    });
    tearDown(() async {
      for (final work in List.of(ActiveWork.all.value)) {
        await ActiveWork.stop(work.session);
      }
      SubtitleStore.overrideDir = null;
      await dir.delete(recursive: true);
    });

    test(
      'two videos on one page have separate records and languages',
      () async {
        const page = 'https://example.test/watch';
        for (final source in [
          'https://cdn.test/v?id=1',
          'https://cdn.test/v?id=2',
        ]) {
          await SubtitleStore.save(
            SavedSubs(
              id: SubtitleStore.idForVideo(page, source),
              title: source,
              page: page,
              source: source,
              language: 'ko',
              updated: DateTime.now(),
              cues: [_old],
              covered: [(0, 5)],
              duration: 100,
            ),
          );
        }
        expect((await SubtitleStore.list()).length, 2);
        final saved = await SubtitleStore.loadVideo(
          page,
          'https://cdn.test/v?id=2',
          duration: 100,
        );
        expect(saved!.source, 'https://cdn.test/v?id=2');
        expect(saved.language, 'ko');
        expect(
          saved.withTitle('new').withCues(saved.cues).withLanguage('en').source,
          saved.source,
        );
        expect(
          await SubtitleStore.loadVideo(page, saved.source, duration: 200),
          isNull,
        );
        expect(
          await SubtitleStore.loadVideo(page, 'https://cdn.test/v?id=3'),
          isNull,
        );
        expect(
          () => SubtitleSession(
            input: 'other',
            videoId: saved.id,
            language: 'auto',
            saved: saved,
          ),
          throwsArgumentError,
        );
      },
    );

    test(
      'legacy page-only subtitles are available for manual selection only',
      () async {
        const page = 'https://example.test/watch';
        await SubtitleStore.save(
          SavedSubs(
            id: SubtitleStore.idFor(page),
            title: 'old',
            page: page,
            language: 'ja',
            updated: DateTime.now(),
            cues: [_old],
            covered: [],
          ),
        );
        expect(
          await SubtitleStore.loadVideo(page, 'https://cdn.test/v'),
          isNull,
        );
        expect((await SubtitleStore.list()).single.title, 'old');
      },
    );

    test(
      'detaching viewers keeps both sessions; stopping one keeps the other',
      () async {
        const page = 'https://example.test/watch';
        final sessions = <SubtitleSession>[];
        for (final source in ['a', 'b']) {
          final id = SubtitleStore.idForVideo(page, source);
          final session = SubtitleSession(
            input: source,
            videoId: id,
            language: 'ko',
          );
          final saver = SessionSaver(
            session: session,
            page: page,
            source: source,
            title: source,
            videoId: id,
            duration: () => 100,
          );
          ActiveWork.begin(id, source, session, saver: saver);
          sessions.add(session);
        }
        var notifications = 0;
        void viewer() {
          notifications++;
        }

        sessions.first.addListener(viewer);
        sessions.first.removeListener(viewer);
        sessions.first.applyCues([_old]);
        await ActiveWork.persist(sessions.first.videoId);
        expect(notifications, 0);
        expect(
          ActiveWork.find(sessions.first.videoId)!.session,
          same(sessions.first),
        );
        expect(
          (await SubtitleStore.loadVideo(page, 'a'))!.cues.single.text,
          'Cũ',
        );
        await ActiveWork.stop(sessions.first);
        expect(ActiveWork.find(sessions.first.videoId), isNull);
        expect(
          ActiveWork.find(sessions.last.videoId)!.session.stopped,
          isFalse,
        );
      },
    );

    test(
      'local subtitles preserve original words and language after reload',
      () async {
        final file = await File('${dir.path}/film.mp4').writeAsBytes([0]);
        final item = VideoItem(file, false);
        await VideoLibrary.saveCues(
          item,
          [_old],
          language: 'en',
          covered: [(0, 10)],
          duration: 100,
          complete: false,
        );
        final cues = await VideoLibrary.loadCues(item);
        expect(cues.single.source, 'Original');
        expect(cues.single.text, 'Cũ');
        expect(await VideoLibrary.subtitleLanguage(item), 'en');
        final state = await VideoLibrary.loadSubtitleState(item);
        expect(state!.covered, [(0.0, 10.0)]);
        expect(state.canResume, isTrue);
        expect(state.source, file.path);
        await VideoLibrary.delete(item);
        expect(await item.subtitleDataFile.exists(), isFalse);
      },
    );
  });

  test(
    'automatic language locks before translation and starts forced recognition',
    () async {
      final dir = await Directory.systemTemp.createTemp('video_language_');
      final workers = <_Worker>[];
      final languages = <String>[];
      final translator = _Translator();
      final session = SubtitleSession(
        input: 'film',
        videoId: 'A',
        language: 'auto',
        parallel: false,
        translator: translator,
        temporaryDirectory: () async => dir,
        retainedAudio: RetainedAudioStore(
          baseDirectory: () async => Directory('${dir.path}/audio'),
        ),
        createFeed: _Feed.new,
        createWorker: (lang) async {
          languages.add(lang);
          final worker = _Worker();
          workers.add(worker);
          return worker;
        },
      )..duration = 100;
      try {
        await session.start(0);
        await _until(() => workers.isNotEmpty);
        final worker = workers.first;
        worker.eventsController.add(AsrSegment(worker.gen, 1, 3, 'one', 'en'));
        worker.eventsController.add(AsrSegment(worker.gen, 5, 7, 'two', 'en'));
        expect(session.language, 'auto');
        expect(translator.calls, isEmpty);
        worker.eventsController.add(
          AsrSegment(worker.gen, 9, 11, 'three', 'en'),
        );
        await _until(() => translator.calls.length == 3 && workers.length == 2);
        expect(session.language, 'en');
        expect(languages, ['auto', 'en']);
        expect(translator.calls.every((c) => c.$2 == 'en'), isTrue);
        workers.last.eventsController.add(
          AsrSegment(workers.last.gen, 15, 17, 'four', 'ja'),
        );
        await _until(() => translator.calls.length == 4);
        expect(session.language, 'en');
        expect(translator.calls.last.$2, 'en');
      } finally {
        session.dispose();
        await _until(() => Directory('${dir.path}/vsub').listSync().isEmpty);
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'late automatic translation cannot overwrite an accepted revision',
    () async {
      final dir = await Directory.systemTemp.createTemp('video_revision_');
      final translator = _Translator()..pending = Completer<String>();
      final session = SubtitleSession(
        input: 'film',
        language: 'en',
        parallel: false,
        translator: translator,
        initialCues: [
          const Cue(start: 2, end: 4, text: 'Original', source: 'Original'),
        ],
        temporaryDirectory: () async => dir,
        retainedAudio: RetainedAudioStore(
          baseDirectory: () async => Directory('${dir.path}/audio'),
        ),
        createFeed: _Feed.new,
        createWorker: (_) async => _Worker(),
      )..duration = 100;
      try {
        await session.start(0);
        await _until(() => translator.calls.isNotEmpty);
        session.applyCues([_old]);
        translator.pending!.complete('Late result');
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(session.cues.single.text, 'Cũ');
      } finally {
        session.dispose();
        await _until(() => Directory('${dir.path}/vsub').listSync().isEmpty);
        await dir.delete(recursive: true);
      }
    },
  );
}
