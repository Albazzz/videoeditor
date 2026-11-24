import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/screens/retained_audio_screen.dart';
import 'package:video/services/active_work.dart';
import 'package:video/services/asr_worker.dart';
import 'package:video/services/audio_feed.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/translator.dart';

Future<void> until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
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
  }) async {
    await File('$outDir/${chunkName(0)}').writeAsBytes([1, 2, 3, 4]);
    await File('$outDir/${chunkName(1)}').writeAsBytes([5, 6, 7, 8]);
    done = true;
  }
}

class _Worker implements AsrWorker {
  final controller = StreamController<AsrEvent>.broadcast(sync: true);
  final paths = <String>[];
  late double base;
  var gen = 0;
  @override
  Stream<AsrEvent> get events => controller.stream;
  @override
  void reset(int gen, double baseSec) {
    this.gen = gen;
    base = baseSec;
  }

  @override
  void feed(int gen, String wavPath, {bool last = false}) {
    paths.add(wavPath);
    File(wavPath).deleteSync(); // Match native worker input ownership.
    scheduleMicrotask(
      () => controller.add(AsrProgress(gen, base + (last ? 8 : 3), last)),
    );
  }

  @override
  Future<void> dispose() async => Future<void>.microtask(controller.close);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late RetainedAudioStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('private_audio_test_');
    store = RetainedAudioStore(
      baseDirectory: () async => Directory('${temp.path}/private'),
    );
  });
  tearDown(() async {
    for (final work in List.of(ActiveWork.all.value)) {
      await ActiveWork.stop(work.session);
    }
    await temp.delete(recursive: true);
  });

  Future<AudioArchive> seed(
    String id, {
    String title = 'Film',
    bool hidden = false,
  }) async {
    final archive = await store.create(id, title: title, hidden: hidden);
    final run = await archive.createRun(1, 20);
    await File('${run.path}/c_00000.wav').writeAsBytes([1, 2, 3, 4]);
    return archive;
  }

  test(
    'audio survives completion, closing and reopening until explicitly confirmed',
    () async {
      final archive = await seed('A');
      await archive.update(completed: true);
      await archive.close();
      final reopened = RetainedAudioStore(
        baseDirectory: () async => Directory('${temp.path}/private'),
      );
      final saved = (await reopened.list()).single;
      expect(
        (
          saved.videoId,
          saved.title,
          saved.bytes,
          saved.chunks,
          saved.completed,
        ),
        ('A', 'Film', 4, 1, true),
      );
      await reopened.deleteConfirmed('A');
      expect(await reopened.list(), isEmpty);
    },
  );

  test('different videos and hidden recordings remain separate', () async {
    final a = await seed('A', title: 'Public');
    final b = await seed('B', title: 'Hidden', hidden: true);
    await a.close();
    await b.close();
    expect((await store.list()).single.title, 'Public');
    expect((await store.list(includeHidden: true)).length, 2);
    await store.deleteConfirmed('A');
    expect(await store.list(), isEmpty);
    expect((await store.list(includeHidden: true)).single.videoId, 'B');
  });

  test(
    'a hidden session hides the whole recording group from the common list',
    () async {
      final first = await seed('A', title: 'Visible before');
      final hidden = await seed('A', title: 'Hidden now', hidden: true);
      await first.close();
      await hidden.close();
      expect(await store.list(), isEmpty);
      expect((await store.list(includeHidden: true)).single.hidden, isTrue);
    },
  );

  test('an archive cannot be deleted while its writer still owns it', () async {
    final archive = await seed('A');
    await expectLater(store.deleteConfirmed('A'), throwsStateError);
    expect((await store.list()).single.chunks, 1);
    await archive.close();
    await store.deleteConfirmed('A');
    expect(await store.list(), isEmpty);
  });

  test(
    'parallel sessions on one video keep their chunks until both close',
    () async {
      final a = await seed('A');
      final b = await seed('A');
      expect((await store.list()).single.chunks, 2);
      await a.close();
      await expectLater(store.deleteConfirmed('A'), throwsStateError);
      await b.close();
      await store.deleteConfirmed('A');
      expect(await store.list(), isEmpty);
    },
  );

  test('video identifiers cannot escape the private directory', () async {
    final sentinel = await File('${temp.path}/keep.wav').writeAsBytes([9]);
    final archive = await seed('../../keep.wav');
    await archive.close();
    await store.deleteConfirmed('../../keep.wav');
    expect(await sentinel.readAsBytes(), [9]);
  });

  test(
    'pipeline gives ASR disposable copies and retains originals after stop',
    () async {
      final worker = _Worker();
      final session = SubtitleSession(
        input: 'film',
        videoId: 'A',
        language: 'en',
        parallel: false,
        translator: PassthroughTranslator(),
        retainedAudio: store,
        temporaryDirectory: () async => temp,
        createWorker: (_) async => worker,
        createFeed: _Feed.new,
      )..duration = 8;
      ActiveWork.begin('A', 'Film', session);
      await session.start(0);
      await until(() => session.finished && worker.paths.length == 2);
      await until(() => ActiveWork.wasCompleted(session));
      expect(ActiveWork.find('A'), isNull);
      expect(session.stopped, isFalse);
      // Stop returns promptly; retained audio writers finish in the background.
      await session.closeAudio();
      await until(() => Directory('${temp.path}/vsub').listSync().isEmpty);
      expect(worker.paths.every((path) => path.contains('vsub')), isTrue);
      final retained = (await store.list()).single;
      expect(retained.bytes, 8);
      expect(retained.chunks, 2);
      expect(retained.completed, isTrue);
      await store.deleteConfirmed('A');
      expect(await store.list(), isEmpty);
    },
  );

  Future<void> show(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(home: RetainedAudioScreen(store: store)),
    );
    for (var i = 0; i < 100 && find.text('Film').evaluate().isEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('cancel keeps audio; only explicit confirmation deletes it', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final a = await seed('A');
      await a.close();
    });
    await show(tester);
    await tester.tap(find.text('Xác nhận…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tiếp tục giữ'));
    await tester.pumpAndSettle();
    expect((await tester.runAsync(() => store.list()))!.single.chunks, 1);
    await tester.tap(find.text('Xác nhận…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Xác nhận xóa'));
    for (var i = 0; i < 100 && find.text('Film').evaluate().isNotEmpty; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => store.list()), isEmpty);
    expect(find.text('Chưa có âm thanh được giữ'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
