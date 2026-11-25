import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/asr_worker.dart';
import 'package:video/services/audio_feed.dart';
import 'package:video/services/full_audio_download.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/translator.dart';

import 'support/pcm_audio.dart';

class _Feed extends AudioFeed {
  String? directory;
  double? startAt, length;
  bool stopped = false;
  bool reject = false;
  int starts = 0;
  Completer<void>? closeGate;
  @override
  Future<void> start({
    required String input,
    required String outDir,
    Map<String, String> headers = const {},
    double startSec = 0,
    double? lengthSec,
    bool hls = false,
  }) async {
    directory = outDir;
    starts++;
    if (reject) {
      error = 'HTTP 403 Forbidden';
      done = true;
    }
    startAt = startSec;
    length = lengthSec;
  }

  Future<void> write(double seconds) => writeAudioChunks(directory!, seconds);
  Future<void> finish(double seconds) async {
    await write(seconds);
    done = true;
  }

  @override
  Future<void> stop() async {
    stopped = true;
    await closeGate?.future;
    done = true;
  }
}

class _Worker implements AsrWorker {
  final controller = StreamController<AsrEvent>.broadcast();
  @override
  Stream<AsrEvent> get events => controller.stream;
  @override
  void reset(int gen, double baseSec) {}
  @override
  void feed(int gen, String path, {bool last = false}) {}
  @override
  Future<void> dispose() => controller.close();
}

class _Translator extends PassthroughTranslator {
  int preparations = 0, calls = 0;
  @override
  TranslatorStatus get status => const TranslatorStatus(TranslationState.ready);
  @override
  Future<void> prepare(String lang) async {
    preparations++;
  }

  @override
  Future<String> translate(String text, String lang) async {
    calls++;
    return 'VI $text';
  }
}

Future<void> _until(bool Function() ready) async {
  final end = DateTime.now().add(const Duration(seconds: 6));
  while (!ready()) {
    if (DateTime.now().isAfter(end)) {
      fail('Timed out waiting for audio pipeline');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RetainedAudioStore store;
  final sessions = <SubtitleSession>[];
  final downloads = <FullAudioDownload>[];
  final archives = <AudioArchive>[];
  final leases = <RetainedAudioLease>[];
  final feeds = <_Feed>[];
  setUp(() async {
    root = await Directory.systemTemp.createTemp('full_audio_');
    store = RetainedAudioStore(
      baseDirectory: () async => Directory('${root.path}/audio'),
    );
    sessions.clear();
    downloads.clear();
    archives.clear();
    leases.clear();
    feeds.clear();
  });
  tearDown(() async {
    for (final feed in feeds) {
      if (feed.closeGate case final gate? when !gate.isCompleted) {
        gate.complete();
      }
    }
    for (final session in sessions) {
      session.requestStop();
      session.dispose();
      await session.closeAudio();
    }
    for (final job in downloads) {
      await job.close();
    }
    for (final lease in leases) {
      await lease.close();
    }
    for (final archive in archives) {
      await archive.close();
    }
    final work = Directory('${root.path}/vsub');
    await _until(() => !work.existsSync() || work.listSync().isEmpty);
    await root.delete(recursive: true);
  });

  Future<FullAudioDownload> job(
    String id,
    _Feed feed, {
    double duration = 38,
    Future<String> Function()? source,
  }) async {
    final archive = await store.create(id, duration: duration);
    archives.add(archive);
    feeds.add(feed);
    var generation = 0;
    final download = FullAudioDownload(
      videoId: id,
      store: store,
      archive: archive,
      duration: () => duration,
      source: source ?? () async => 'original.mp4',
      retryDelay: Duration.zero,
      headers: () => const {},
      hls: () => false,
      createFeed: () => feed,
      nextGeneration: () => ++generation,
      onProgress: (_) {},
      onStatus: (_) {},
    );
    downloads.add(download);
    return download;
  }

  test(
    'no model, recognizer or translation starts before full audio; seeks do not restart downloading',
    () async {
      final feed = _Feed();
      feeds.add(feed);
      final translator = _Translator();
      var workers = 0, starts = 0;
      final session = SubtitleSession(
        input: 'original.mp4',
        videoId: 'A',
        language: 'en',
        parallel: false,
        translator: translator,
        retainedAudio: store,
        initialCues: const [
          Cue(start: 0, end: 1, text: 'Hello', source: 'Hello'),
        ],
        temporaryDirectory: () async => root,
        createFeed: () {
          starts++;
          return feed;
        },
        createWorker: (_) async {
          workers++;
          return _Worker();
        },
      )..duration = 38;
      sessions.add(session);
      await session.start(25);
      await _until(() => feed.directory != null);
      expect((feed.startAt, feed.length), (0, 38));
      await feed.write(8);
      await _until(() => session.audioAvailability.seconds >= 8);
      expect(session.audioAvailability.complete, false);
      expect(session.progressFraction, greaterThan(0));
      expect(session.progressFraction, lessThan(1));
      expect(workers, 0);
      expect(translator.preparations, 0);
      expect(translator.calls, 0);
      for (var i = 0; i < 3; i++) {
        session.updatePosition(30);
      }
      expect(starts, 1);
      await feed.finish(38);
      await _until(() => workers == 1 && translator.preparations == 1);
      expect(session.audioAvailability.percent, 100);
      expect(starts, 1);
    },
  );

  test(
    'one video holds the download slot through EOF and writer close before the next video starts',
    () async {
      final a = _Feed(), b = _Feed();
      final first = await job('A', a), second = await job('B', b);
      final fa = first.run();
      await _until(() => a.directory != null);
      final fb = second.run();
      a.closeGate = Completer<void>();
      await a.finish(38);
      await _until(() => a.stopped);
      expect(b.directory, isNull);
      a.closeGate!.complete();
      leases.add((await fa)!);
      await _until(() => b.directory != null);
      await b.finish(38);
      leases.add((await fb)!);
      expect(leases.every((l) => l.availability(duration: 38).complete), true);
    },
  );

  test(
    'cancelling a queued video never starts it and never occupies the next slot',
    () async {
      final a = _Feed(), b = _Feed(), c = _Feed();
      final first = await job('A', a),
          second = await job('B', b),
          third = await job('C', c);
      final fa = first.run();
      await _until(() => a.directory != null);
      final fb = second.run();
      final fc = third.run();
      second.cancel();
      expect(await fb, isNull);
      expect(b.directory, isNull);
      await a.finish(38);
      leases.add((await fa)!);
      await _until(() => c.directory != null);
      await c.finish(38);
      leases.add((await fc)!);
      expect(b.directory, isNull);
    },
  );

  test(
    'cancelled partial audio is retained and the next session downloads only the missing tail',
    () async {
      final a = _Feed();
      final first = await job('A', a);
      final fa = first.run();
      await _until(() => a.directory != null);
      await a.write(8);
      first.cancel();
      expect(await fa, isNull);
      final before = (await store.list()).single.bytes;
      final b = _Feed();
      final resumed = await job('A', b);
      final fb = resumed.run();
      await _until(() => b.directory != null);
      expect((b.startAt, b.length), (8, 30));
      await b.finish(30);
      leases.add((await fb)!);
      final audio = (await store.list()).single;
      expect(audio.availability.complete, true);
      expect(audio.bytes, greaterThan(before));
    },
  );

  test(
    'a successful EOF supplies the total when video duration is unknown',
    () async {
      final feed = _Feed();
      final download = await job('A', feed, duration: 0);
      final future = download.run();
      await _until(() => feed.directory != null);
      expect(feed.length, isNull);
      await feed.finish(38);
      final lease = (await future)!;
      leases.add(lease);
      expect(lease.availability().complete, true);
      expect(lease.availability().total, 38);
    },
  );

  test(
    'a complete retained recording needs no source and no new download',
    () async {
      final archive = await store.create('A', duration: 38);
      archives.add(archive);
      final run = await archive.createRun(1, 0);
      await writeAudioChunks(run.path, 38);
      await archive.recordRunEnd(1, 0, videoDuration: 38);
      await archive.close();
      final feed = _Feed();
      final download = await job(
        'A',
        feed,
        source: () => throw StateError('Website is blocked'),
      );
      final lease = (await download.run())!;
      leases.add(lease);
      expect(feed.directory, isNull);
      expect(lease.availability(duration: 38).percent, 100);
    },
  );

  test(
    'cancelling during source resolution releases the slot without waiting for the website',
    () async {
      final source = Completer<String>();
      final feed = _Feed();
      final download = await job('A', feed, source: () => source.future);
      final future = download.run();
      await _until(() => download.connecting);
      download.cancel();
      expect(await future.timeout(const Duration(seconds: 1)), isNull);
      expect(feed.directory, isNull);
      source.complete('original.mp4');
    },
  );

  test(
    'denied source retries finitely and never declares complete audio',
    () async {
      final feed = _Feed()..reject = true;
      final download = await job('A', feed);
      await expectLater(download.run(), throwsStateError);
      expect(feed.starts, 3);
      expect((await store.availability('A', duration: 38)).complete, false);
    },
  );
}
