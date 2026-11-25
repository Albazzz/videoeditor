import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/audio_availability.dart';

void main() {
  test('overlapping downloads count once and real gaps remain missing', () {
    final audio = AudioAvailability(
      duration: 40,
      ranges: [(0, 10), (5, 15), (20, 30)],
    );
    expect(audio.seconds, 25);
    expect(audio.percent, 62);
    expect(audio.firstMissing, 15);
    expect(audio.complete, false);
  });

  test('a missing tail or middle never rounds up to 100 percent', () {
    final tail = AudioAvailability(duration: 100, ranges: [(0, 99.99)]);
    final hole = AudioAvailability(
      duration: 100,
      ranges: [(0, 50), (50.5, 100)],
    );
    expect(tail.percent, 99);
    expect(tail.complete, false);
    expect(hole.percent, 99);
    expect(hole.complete, false);
    expect(hole.firstMissing, 50);
  });

  test('unknown length stays unknown until a real audio EOF is available', () {
    final unknown = AudioAvailability(ranges: [(0, 38)]);
    expect(unknown.percent, isNull);
    expect(unknown.complete, false);
    final ended = AudioAvailability(ranges: [(0, 38)], endOfAudio: 38);
    expect(ended.percent, 100);
    expect(ended.complete, true);
  });
}
