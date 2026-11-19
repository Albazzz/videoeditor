import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/active_work.dart';
import 'package:video/services/open_page.dart';
import 'package:video/services/subtitle_session.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/services/video_pipeline.dart';

/// One piece of work asking for a recogniser.
class _Job {
  _Job(this.slots, this.name, this.priority);
  final PrioritySlots slots;
  final String name;
  int priority;
  void Function()? release;
  bool asked = false;
  late final Future<void> granted = slots
      .acquire(priority: () => priority, onPreempt: () => asked = true)
      .then((r) => release = r);
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recognisers by priority', () {
    test(
      'the stretch ahead of the viewer takes over from background work',
      () async {
        final slots = PrioritySlots(2);
        final a = _Job(slots, 'film B, filling', 2)..granted;
        final b = _Job(slots, 'film A, behind', 1)..granted;
        await settle();
        expect(slots.holding, 2);
        final urgent = _Job(slots, 'film A, ahead', 0)..granted;
        await settle();
        // The least urgent holder is asked to give way; the other is not.
        expect(a.asked, isTrue);
        expect(b.asked, isFalse);
        expect(urgent.release, isNull);
        a.release!();
        await settle();
        expect(urgent.release, isNotNull, reason: 'given the freed recogniser');
      },
    );

    test(
      'equal priority never interrupts, and nothing waits for good',
      () async {
        final slots = PrioritySlots(1);
        final first = _Job(slots, 'film B', 2)..granted;
        await settle();
        final second = _Job(slots, 'film C', 2)..granted;
        await settle();
        expect(first.asked, isFalse);
        first.release!();
        await settle();
        // Background work runs as soon as nothing more urgent waits.
        expect(second.release, isNotNull);
      },
    );

    test('a seek makes the new place urgent at the next decision', () async {
      final slots = PrioritySlots(1);
      final holder = _Job(slots, 'run 1', 1)..granted;
      await settle();
      final other = _Job(slots, 'run 2', 1)..granted;
      await settle();
      expect(holder.asked, isFalse);
      other.priority = 0; // the viewer jumped into run 2's stretch
      slots.reprioritize();
      expect(holder.asked, isTrue);
    });

    test('memory pressure leaves one recogniser', () async {
      final slots = PrioritySlots(2);
      final a = _Job(slots, 'a', 0)..granted;
      final b = _Job(slots, 'b', 2)..granted;
      await settle();
      slots.capacity = 1;
      expect(b.asked, isTrue);
      expect(a.asked, isFalse);
    });
  });

  test('a running film is found again under a new signed address', () {
    const page = 'https://phim.example/xem/1';
    final session = SubtitleSession(
      input: 'https://cdn.example/v.m3u8?hash=A',
      language: 'zh',
    )..duration = 5400;
    final saver = SessionSaver(session: session, page: page, title: 'Phim');
    ActiveWork.begin('id-old', 'Phim', session, saver: saver);
    addTearDown(() {
      ActiveWork.end(session);
      session.dispose();
    });
    expect(ActiveWork.findVideo('id-new', page, 5401)?.session, session);
    expect(ActiveWork.findVideo('id-new', page, 1200), isNull);
    expect(ActiveWork.onPage('$page#t=30')?.session, session);
  });

  test(
    'stopping finishes within 3 s even if saving hangs, and can carry on',
    () async {
      const page = 'https://phim.example/xem/2';
      final session = SubtitleSession(
        input: 'https://cdn.example/b.mp4',
        language: 'ja',
      );
      final saver = SessionSaver(session: session, page: page, title: 'Phim 2');
      final hang = Completer<void>();
      ActiveWork.begin(
        'id-2',
        'Phim 2',
        session,
        saver: saver,
        onSave: (_) => hang.future,
      );
      final watch = Stopwatch()..start();
      await ActiveWork.stop(session);
      expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
      expect(ActiveWork.isRunning(session), isFalse);
      expect(ActiveWork.wasStopped(session), isTrue);
      expect(ActiveWork.stopped.value.single.page, page);
      // "Làm tiếp" asks the browser once to carry on when the film plays.
      requestResume(page);
      expect(takeResume('$page#x'), isTrue);
      expect(takeResume(page), isFalse);
      ActiveWork.forgetStopped('id-2');
      expect(ActiveWork.stopped.value, isEmpty);
      hang.complete();
    },
  );

  test('"Làm lại từ đầu" opens the page once, fresh, unlike "Làm tiếp"', () {
    const page = 'https://phim.example/xem/3';
    requestResume(page);
    expect(takeResume(page), isTrue);
    expect(takeRestart(page), isFalse, reason: 'carrying on keeps the lines');
    requestRestart('$page#t=10');
    expect(takeResume(page), isTrue);
    expect(takeRestart(page), isTrue);
    expect(takeRestart(page), isFalse);
  });

  test('saved subtitles keep their key helpers in step', () {
    expect(
      SubtitleStore.idForVideo('https://a.example/x', 's'),
      isNot(SubtitleStore.idForVideo('https://a.example/x', 't')),
    );
  });
}
