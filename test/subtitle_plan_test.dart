import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/widgets/activity_icon.dart';

void main() {
  progressTests();
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

void progressTests() {
  test(
    'a new session lists every step and waits before loading recognition',
    () {
      final s = SubtitleSession(
        input: 'https://cdn.example/v.m3u8',
        language: 'ja',
      );
      final steps = s.steps;
      expect(steps.length, 7);
      expect(steps.first.state, StageState.done);
      expect(steps.first.detail, 'cdn.example');
      expect(steps[1].state, StageState.waiting);
      expect(steps[1].detail, 'Chờ lượt nhận dạng');
      // No translator on this machine: translating is skipped, not stuck.
      expect(steps[2].state, StageState.skipped);
      expect(steps.last.state, StageState.skipped);
      expect(s.activity, SessionActivity.working);
      s.dispose();
    },
  );

  testWidgets('the progress sheet opens from the icon', (tester) async {
    final s = SubtitleSession(
      input: 'https://cdn.example/v.m3u8',
      language: 'ja',
    )..duration = 600;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ActivityIcon(session: s, title: 'Phim'),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(ActivityIcon));
    // The sheet slides up; the icons keep ticking, so no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Phim'), findsOneWidget);
    expect(find.text('1. Tìm video trên trang'), findsOneWidget);
    expect(find.text('7. Dịch sang tiếng Việt'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    s.dispose();
  });
}
