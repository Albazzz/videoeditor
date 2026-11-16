import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/subtitle_session.dart';

void main() {
  group('what to work on next', () {
    const film = 6000.0;

    test('started mid-film: after reaching the end, the opening is done', () {
      // Watched from 30:00 to the end.
      const covered = [(1800.0, 6000.0)];
      expect(
        nextStart(
          covered: covered,
          duration: film,
          position: 2000,
          mode: SubtitleMode.whole,
        ),
        0,
      );
      // Following only cares about what is ahead of the viewer.
      expect(
        nextStart(
          covered: covered,
          duration: film,
          position: 2000,
          mode: SubtitleMode.follow,
        ),
        isNull,
      );
    });

    test('a gap ahead of the viewer comes before one behind', () {
      const covered = [(0.0, 600.0), (1200.0, 1500.0), (2000.0, 6000.0)];
      expect(
        nextStart(
          covered: covered,
          duration: film,
          position: 1300,
          mode: SubtitleMode.whole,
        ),
        1500,
      );
    });

    test('a viewer inside a gap is served from where they are', () {
      const covered = [(0.0, 600.0)];
      expect(
        nextStart(
          covered: covered,
          duration: film,
          position: 3000,
          mode: SubtitleMode.follow,
        ),
        3000,
      );
    });

    test('nothing to do when all is covered or the length is unknown', () {
      for (final mode in SubtitleMode.values) {
        expect(
          nextStart(
            covered: const [(0, 3000), (2990, 5999)],
            duration: film,
            position: 10,
            mode: mode,
          ),
          isNull,
        );
        expect(
          nextStart(covered: const [], duration: 0, position: 10, mode: mode),
          isNull,
        );
      }
    });

    test('a run stops where subtitles already exist', () {
      const covered = [(1800.0, 6000.0), (0.0, 300.0)];
      expect(runEnd(covered, 300), 1802);
      expect(runEnd(covered, 1900), isNull);
      expect(runEnd(const [], 0), isNull);
    });
  });

  test('sounds are not sent for translation, words are', () {
    for (final noise in [
      '嗯',
      '嗯嗯。',
      'あっ',
      'ああ…',
      'Hmm...',
      '🎼',
      '  ',
      '呃，啊',
    ]) {
      expect(isFiller(noise), isTrue, reason: noise);
    }
    for (final words in ['うん', 'はい', '好', '你好', 'Oh no', 'あの人']) {
      expect(isFiller(words), isFalse, reason: words);
    }
  });
}
