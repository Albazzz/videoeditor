import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/active_work.dart';
import 'package:video/services/asr_worker.dart';
import 'package:video/services/audio_feed.dart';
import 'package:video/services/background_subtitles.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_resume.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/services/translator.dart';
import 'package:video/widgets/subtitle_pipeline_progress.dart';

Uint8List _wav(double seconds) {
  final samples = (seconds * 16000).round();
  final bytes = Uint8List(44 + samples * 2);
  void tag(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  final data = ByteData.sublistView(bytes);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  return bytes;
}

class _Worker implements AsrWorker {
  final controller = StreamController<AsrEvent>.broadcast(sync: true);
  final starts = <double>[];
  int gen = 0;
  double at = 0;
  bool stopped = false;
  bool emitEvents = true;
  @override
  Stream<AsrEvent> get events => controller.stream;
  @override
  void reset(int gen, double baseSec) {
    this.gen = gen;
    at = baseSec;
  }

  @override
  void feed(int gen, String path, {bool last = false}) {
    final duration = readPcm16Wav(File(path).readAsBytesSync()).length / 16000;
    starts.add(at);
    final start = at;
    at += duration;
    File(path).deleteSync();
    if (!emitEvents) return;
    scheduleMicrotask(() {
      if (stopped) return;
      controller.add(
        AsrSegment(gen, start + .2, start + 1, 'Voice $start', 'en'),
      );
      controller.add(AsrProgress(gen, at, last));
    });
  }

  @override
  Future<void> dispose() async {
    stopped = true;
    await Future<void>.microtask(controller.close);
  }
}

class _CompleteFeed extends AudioFeed {
  @override
  Future<void> start({
    required String input,
    required String outDir,
    Map<String, String> headers = const {},
    double startSec = 0,
    double? lengthSec,
    bool hls = false,
  }) async {
    const lengths = [3.0, 5.0, 10.0, 10.0, 10.0];
    for (var i = 0; i < lengths.length; i++) {
      await File('$outDir/${chunkName(i)}').writeAsBytes(_wav(lengths[i]));
    }
    done = true;
  }
}

class _Translator extends PassthroughTranslator {
  @override
  TranslatorStatus get status => const TranslatorStatus(TranslationState.ready);
  @override
  Future<String> translate(String text, String lang) async => 'VI: $text';
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 6));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RetainedAudioStore store;
  late SubtitleResume resume;
  final workers = <_Worker>[];
  var modelChecks = 0;
  SavedSubs saved({
    double duration = 38,
    List<(double, double)> covered = const [(0, 18)],
    List<Cue> cues = const [
      Cue(start: 0, end: 1, text: 'Đã dịch', source: 'Already done'),
    ],
  }) => SavedSubs(
    id: 'A',
    title: 'Film',
    page: 'https://example.org/movie',
    source: 'https://expired.example/old.mp4',
    language: 'en',
    updated: DateTime(2026),
    duration: duration,
    cues: cues,
    covered: covered,
  );
  Future<void> seed({
    String id = 'A',
    bool eof = false,
    List<int>? indices,
    bool hidden = false,
  }) async {
    final archive = await store.create(
      id,
      title: 'Film',
      hidden: hidden,
      source: 'https://expired.example/old.mp4',
      page: 'https://example.org/movie',
      language: 'en',
      duration: 38,
    );
    final dir = await archive.createRun(1, 0);
    const lengths = [3.0, 5.0, 10.0, 10.0, 10.0];
    for (final i in indices ?? [0, 1, 2, 3, 4]) {
      await File(
        '${dir.path}/c_${i.toString().padLeft(5, '0')}.wav',
      ).writeAsBytes(_wav(lengths[i]));
    }
    if (eof) await archive.recordRunEnd(1, 0, videoDuration: 38);
    await archive.close();
  }

  Future<SubtitleResumeResult> start(SavedSubs sub) => resume.resume(
    sub,
    ensureRecognition: () async {
      modelChecks++;
      return true;
    },
  );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('audio_resume_');
    SubtitleStore.overrideDir = root;
    store = RetainedAudioStore(
      baseDirectory: () async => Directory('${root.path}/audio'),
    );
    workers.clear();
    modelChecks = 0;
    BackgroundSubtitles.instance.dismiss();
    resume = SubtitleResume(
      audio: store,
      createSession: (saved, lease) => SubtitleSession(
        input: saved.source,
        videoId: saved.id,
        language: saved.language,
        saved: saved,
        retainedOnly: true,
        retainedInput: lease,
        retainedAudio: store,
        parallel: false,
        temporaryDirectory: () async => root,
        translator: _Translator(),
        createWorker: (_) async {
          final worker = _Worker();
          workers.add(worker);
          return worker;
        },
        createFeed: () =>
            throw StateError('Must not download or extract video'),
      ),
    );
  });
  tearDown(() async {
    for (final work in List.of(ActiveWork.all.value)) {
      await ActiveWork.stop(work.session);
      await work.session.closeAudio();
    }
    await ActiveWork.waitForAudio('A');
    BackgroundSubtitles.instance.dismiss();
    SubtitleStore.overrideDir = null;
    await root.delete(recursive: true);
  });

  test(
    'uses cached WAVs, skips completed chunks, keeps originals and timestamps',
    () async {
      await seed();
      final bytes = (await store.list()).single.bytes;
      final sub = saved();
      await SubtitleStore.save(sub);
      expect(await start(sub), SubtitleResumeResult.started);
      final session = ActiveWork.find('A')!.session;
      expect(session.audioAvailability.percent, 100);
      expect(session.covered, [(0.0, 18.0)]);
      expect(
        session.steps.any(
          (s) => s.detail.contains('không kết nối lại trang web'),
        ),
        true,
      );
      await _until(() => ActiveWork.wasCompleted(session));
      expect(workers.single.starts, [18.0, 28.0]);
      expect(modelChecks, 1);
      final kept = (await store.list()).single;
      expect(kept.chunks, 5);
      expect(kept.bytes, bytes);
      expect(kept.completed, true);
      final result = (await SubtitleStore.load('A'))!;
      expect(result.cues.first.text, 'Đã dịch');
      expect(result.cues.map((c) => c.start), [0, 18.2, 28.2]);
      expect(result.cues.skip(1).every((c) => c.text.startsWith('VI:')), true);
      expect(result.isWholeVideo, true);
    },
  );

  test(
    'recognised original text can finish translating without audio or web',
    () async {
      final sub = saved(
        duration: 100,
        covered: [(0, 100)],
        cues: [const Cue(start: 1, end: 2, text: 'Hello', source: 'Hello')],
      );
      await SubtitleStore.save(sub);
      expect(await start(sub), SubtitleResumeResult.started);
      final session = ActiveWork.find('A')!.session;
      await _until(() => ActiveWork.wasCompleted(session));
      expect(workers, isEmpty);
      expect(modelChecks, 0);
      expect((await SubtitleStore.load('A'))!.cues.single.text, 'VI: Hello');
    },
  );

  test(
    'download can reach 100 percent while recognition is still waiting',
    () async {
      final worker = _Worker()..emitEvents = false;
      final session = SubtitleSession(
        input: 'test.mp4',
        videoId: 'A',
        language: 'en',
        retainedAudio: store,
        parallel: false,
        temporaryDirectory: () async => root,
        translator: _Translator(),
        createFeed: _CompleteFeed.new,
        createWorker: (_) async => worker,
      )..duration = 38;
      try {
        await session.start(0);
        await _until(() => session.audioAvailability.complete);
        expect(session.audioAvailability.percent, 100);
        expect(session.covered, isEmpty);
        expect(session.readyToFinish, false);
        expect((await store.list()).single.availability.complete, true);
      } finally {
        session.requestStop();
        session.dispose();
        await session.closeAudio();
      }
    },
  );

  testWidgets(
    'cached work visibly advances recognition independently of downloaded audio',
    (tester) async {
      await tester.runAsync(() async {
        await seed();
        await start(saved());
      });
      final session = ActiveWork.find('A')!.session;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SubtitlePipelineProgress(session: session)),
        ),
      );
      expect(find.text('Âm thanh đã lưu: 100% · 0:38 / 0:38'), findsOneWidget);
      expect(find.text('Đã nhận dạng: 47% · 0:18 / 0:38'), findsOneWidget);
      await tester.runAsync(
        () => _until(() => session.covered.single.$2 >= 28),
      );
      await tester.pump();
      expect(find.text('Đã nhận dạng: 73% · 0:28 / 0:38'), findsOneWidget);
      expect(find.text('Đã dịch: 2 / 2 câu đã nhận dạng'), findsOneWidget);
      expect(find.text('Âm thanh đã lưu: 100% · 0:38 / 0:38'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'partial cache waits for a source before any new recognition or translation',
    () async {
      await seed();
      final sub = saved(duration: 58);
      await SubtitleStore.save(sub);
      expect(await start(sub), SubtitleResumeResult.needsSource);
      expect(ActiveWork.find('A'), isNull);
      expect(workers, isEmpty);
      expect(modelChecks, 0);
      expect((await SubtitleStore.load('A'))!.covered, [(0.0, 18.0)]);
      expect(
        (await store.list()).single.availability.withDuration(58).percent,
        65,
      );
      expect((await store.list()).single.chunks, 5);
    },
  );

  test(
    'stopping and resuming uses the newest checkpoint instead of replaying finished audio',
    () async {
      await seed();
      final sub = saved();
      await SubtitleStore.save(sub);
      await start(sub);
      await _until(() => workers.isNotEmpty && workers.first.starts.isNotEmpty);
      final first = ActiveWork.find('A')!.session;
      await ActiveWork.stop(first);
      await ActiveWork.waitForAudio('A');
      expect(await start(sub), SubtitleResumeResult.started);
      final next = ActiveWork.find('A')!.session;
      await _until(() => ActiveWork.wasCompleted(next));
      expect(workers.first.starts, [18.0]);
      expect(workers.last.starts, [28.0]);
      expect((await store.list()).single.chunks, 5);
    },
  );

  test(
    'no cached audio returns needsSource and never launches a recogniser',
    () async {
      expect(await start(saved()), SubtitleResumeResult.needsSource);
      expect(workers, isEmpty);
      expect(modelChecks, 0);
      expect(ActiveWork.find('A'), isNull);
    },
  );

  test(
    'an extraction EOF lets an unknown-duration video finish from retained audio',
    () async {
      await seed(eof: true);
      final sub = saved(duration: 0);
      await SubtitleStore.save(sub);
      await start(sub);
      final session = ActiveWork.find('A')!.session;
      await _until(() => ActiveWork.wasCompleted(session));
      expect((await SubtitleStore.load('A'))!.complete, true);
      expect(session.needsAudioSource, false);
    },
  );

  test(
    'missing WAV indices keep their gaps; active readers block deletion',
    () async {
      await seed(indices: [0, 2, 3, 4]);
      final lease = (await store.acquire('A'))!;
      expect(lease.chunks.map((c) => c.start), [0, 8, 18, 28]);
      await expectLater(store.deleteConfirmed('A'), throwsStateError);
      final plans = planRetainedAudio(lease.chunks, [], [], 2);
      expect(plans.map((g) => (g.first.start, g.last.end)), [
        (0.0, 3.0),
        (8.0, 38.0),
      ]);
      await lease.close();
      await store.deleteConfirmed('A');
      expect(await store.list(), isEmpty);
    },
  );

  test(
    'unfinished WAVs are excluded even when audio files occupy disk space',
    () async {
      await seed();
      final lease = (await store.acquire('A'))!;
      final unfinished = lease.chunks[2].file;
      await lease.close();
      final bytes = await unfinished.readAsBytes();
      ByteData.sublistView(bytes).setUint32(40, 0xffffffff, Endian.little);
      await unfinished.writeAsBytes(bytes);
      final audio = (await store.list()).single;
      expect(audio.bytes, greaterThan(0));
      expect(audio.availability.percent, 73);
      expect(audio.availability.complete, false);
      expect(audio.availability.firstMissing, 8);
    },
  );

  test(
    'read leases never cross video identities or reveal hidden recordings',
    () async {
      await seed(id: 'B');
      expect(await store.acquire('A'), isNull);
      await seed(hidden: true);
      expect(await store.acquire('A'), isNull);
      final hidden = (await store.acquire('A', includeHidden: true))!;
      expect(hidden.chunks, hasLength(5));
      await hidden.close();
    },
  );
}
