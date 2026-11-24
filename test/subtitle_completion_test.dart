import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/active_work.dart';
import 'package:video/services/background_subtitles.dart';
import 'package:video/services/bookmarks.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/services/translator.dart';

class _Translator extends PassthroughTranslator {
  Completer<void>? preparation;
  Completer<String>? translation;
  bool fail = false;
  int calls = 0;
  @override
  TranslatorStatus get status => const TranslatorStatus(TranslationState.ready);
  @override
  Future<void> prepare(String lang) async {
    await preparation?.future;
  }

  @override
  Future<String> translate(String text, String lang) async {
    calls++;
    if (fail) throw StateError('offline');
    return await translation?.future ?? 'Xin chào';
  }
}

Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('Timed out');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late RetainedAudioStore audio;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('completion_');
    SubtitleStore.overrideDir = root;
    audio = RetainedAudioStore(
      baseDirectory: () async => Directory('${root.path}/audio'),
    );
    BackgroundSubtitles.instance.dismiss();
    final archive = await audio.create('A');
    final run = await archive.createRun(1, 0);
    await File('${run.path}/c_00000.wav').writeAsBytes([1, 2, 3, 4]);
    await archive.close();
  });
  tearDown(() async {
    for (final work in List.of(ActiveWork.all.value)) {
      await ActiveWork.stop(work.session);
      await work.session.closeAudio();
    }
    BackgroundSubtitles.instance.dismiss();
    SubtitleStore.overrideDir = null;
    await root.delete(recursive: true);
  });

  SubtitleSession make(
    _Translator translator, {
    Future<void> Function(SubtitleSession)? onSave,
  }) {
    final session = SubtitleSession(
      input: 'film.mp4',
      videoId: 'A',
      language: 'en',
      translator: translator,
      retainedAudio: audio,
      temporaryDirectory: () async => root,
      initialCovered: const [(0, 100)],
      initialCues: const [
        Cue(start: 0, end: 1, text: 'Hello', source: 'Hello'),
      ],
    )..duration = 100;
    final saver = SessionSaver(
      session: session,
      page: 'https://example.org/film',
      source: 'film.mp4',
      title: 'Private film name',
      videoId: 'A',
      duration: () => 100,
    );
    ActiveWork.begin(
      'A',
      'Private film name',
      session,
      saver: saver,
      onSave: onSave,
    );
    return session;
  }

  test(
    'finishes only after translation and final save; keeps audio and unclassifies',
    () async {
      final engine = _Translator()
        ..preparation = Completer<void>()
        ..translation = Completer<String>();
      final saved = Completer<void>();
      var saving = false;
      final session = make(
        engine,
        onSave: (_) async {
          saving = true;
          await saved.future;
        },
      );
      await Bookmarks.moveSubtitles(['A'], 'Phim');
      await session.start(0);
      expect(session.finished, true);
      expect(session.readyToFinish, false);
      engine.preparation!.complete();
      await _until(() => engine.calls == 1);
      expect(ActiveWork.find('A'), isNotNull);
      expect(BackgroundSubtitles.instance.state.value.completed, 0);
      engine.translation!.complete('Xin chào');
      await _until(() => saving);
      expect(ActiveWork.find('A'), isNotNull);
      expect(BackgroundSubtitles.instance.state.value.completed, 0);
      saved.complete();
      await _until(() => ActiveWork.wasCompleted(session));
      expect(ActiveWork.find('A'), isNull);
      expect(ActiveWork.all.value, isEmpty);
      expect(ActiveWork.stopped.value.where((w) => w.id == 'A'), isEmpty);
      expect(session.stopped, false);
      expect((await SubtitleStore.load('A'))!.cues.single.text, 'Xin chào');
      expect((await Bookmarks.subtitleFolders())['A'], isNull);
      final retained = (await audio.list()).single;
      expect(retained.bytes, 4);
      expect(retained.completed, true);
      expect(
        BackgroundSubtitles.instance.state.value.label,
        'Sub: 1/1 hoàn thành',
      );
    },
  );

  test(
    'a failed translation remains retryable and never archives as complete',
    () async {
      final engine = _Translator()..fail = true;
      final session = make(engine);
      await session.start(0);
      await _until(() => session.canRetry);
      expect(session.activity, SessionActivity.failed);
      expect(ActiveWork.wasCompleted(session), false);
      expect(ActiveWork.find('A'), isNotNull);
      expect(BackgroundSubtitles.instance.state.value.completed, 0);
      engine.fail = false;
      await session.retry();
      await _until(() => ActiveWork.wasCompleted(session));
      expect((await SubtitleStore.load('A'))!.cues.single.text, 'Xin chào');
      expect(BackgroundSubtitles.instance.state.value.completed, 1);
    },
  );

  test(
    'failed final persistence stays active until a successful retry',
    () async {
      var failSave = true;
      final session = make(
        _Translator(),
        onSave: (_) async {
          if (failSave) throw const FileSystemException('disk unavailable');
        },
      );
      await session.start(0);
      await _until(() => session.error != null);
      expect(ActiveWork.wasCompleted(session), false);
      expect(BackgroundSubtitles.instance.state.value.completed, 0);
      expect(ActiveWork.find('A'), isNotNull);
      failSave = false;
      await session.retry();
      await _until(() => ActiveWork.wasCompleted(session));
      expect(BackgroundSubtitles.instance.state.value.completed, 1);
    },
  );
}
