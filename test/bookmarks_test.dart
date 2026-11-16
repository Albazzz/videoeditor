import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/services/bookmarks.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('saved pages: newest first, one per page, removable', () async {
    await Bookmarks.add('https://a.example/phim-1', 'Phim 1');
    await Bookmarks.add('https://b.example/phim-2', 'Phim 2');
    // Saving again (with a #fragment) moves it to the top, not twice.
    await Bookmarks.add('https://a.example/phim-1#t=30', 'Phim 1');
    final all = await Bookmarks.load();
    expect(all.map((b) => b.title), ['Phim 1', 'Phim 2']);
    expect(all.first.host, 'a.example');
    expect(await Bookmarks.contains('https://b.example/phim-2'), isTrue);

    await Bookmarks.remove('https://a.example/phim-1');
    expect((await Bookmarks.load()).map((b) => b.title), ['Phim 2']);
    expect(await Bookmarks.contains('https://a.example/phim-1'), isFalse);
  });
}
