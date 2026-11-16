import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/services/audio_feed.dart';
import 'package:video/services/watch_position.dart';

void main() {
  test('audio is cut short at first, then every 10 seconds', () {
    final points = segmentTimes(hours: 1).split(',').map(int.parse).toList();
    expect(points.take(4), [3, 8, 18, 28]);
    expect(points.last, lessThanOrEqualTo(3600));
    expect(points.last, greaterThan(3590));
  });

  group('watch position', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('remembers where a film stopped', () async {
      await WatchPosition.save('a', 754.2, 5400);
      expect(await WatchPosition.load('a', duration: 5400), 754.2);
    });

    test('forgets a film watched to the end', () async {
      await WatchPosition.save('a', 754, 5400);
      await WatchPosition.save('a', 5390, 5400);
      expect(await WatchPosition.load('a', duration: 5400), isNull);
    });

    test('ignores adverts, the opening and another episode', () async {
      await WatchPosition.save('ad', 20, 30);
      expect(await WatchPosition.load('ad'), isNull);
      await WatchPosition.save('b', 8, 5400);
      expect(await WatchPosition.load('b', duration: 5400), isNull);
      await WatchPosition.save('c', 900, 5400);
      expect(await WatchPosition.load('c', duration: 2700), isNull);
      expect(await WatchPosition.load('c'), 900);
    });
  });
}
