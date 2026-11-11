// Runs the real speech pipeline end to end (model download, ffmpeg audio
// decode, VAD, recognition) on a desktop build:
//   flutter test integration_test/pipeline_test.dart -d windows \
//     --dart-define=SAMPLE=C:\path\to\japanese.wav

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:video/services/model_store.dart';
import 'package:video/services/subtitle_session.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('transcribes a sample with timestamps', (tester) async {
    const sample = String.fromEnvironment('SAMPLE');
    const lang = String.fromEnvironment('LANG_CODE', defaultValue: 'ja');
    expect(sample, isNotEmpty, reason: 'pass --dart-define=SAMPLE=<file>');

    await tester.runAsync(() async {
      if (!await ModelStore.isReady()) {
        var shown = -1;
        await ModelStore.download((v) {
          final pct = (v * 10).floor();
          if (pct != shown) {
            shown = pct;
            // ignore: avoid_print
            print('model download ${pct * 10}%');
          }
        });
      }
      final session = SubtitleSession(input: sample, language: lang);
      final watch = Stopwatch()..start();
      await session.start(0);
      while (!session.finished && session.error == null) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (watch.elapsed > const Duration(minutes: 5)) break;
      }
      // Let queued translations land.
      await Future<void>.delayed(const Duration(milliseconds: 500));
      // ignore: avoid_print
      print(
        'done in ${watch.elapsedMilliseconds} ms, '
        'processed ${session.processedUntil.toStringAsFixed(1)} s',
      );
      for (final c in session.cues) {
        // ignore: avoid_print
        print(
          '[${c.start.toStringAsFixed(2)} - ${c.end.toStringAsFixed(2)}] '
          '${c.text}',
        );
      }
      expect(session.error, isNull);
      expect(session.finished, isTrue);
      expect(session.cues, isNotEmpty);
      session.dispose();
    });
  });
}
