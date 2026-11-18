import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/widgets/bookmarks_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/services/bookmarks.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'legacy pages, empty folders, renames, moves and concurrent saves',
    () async {
      SharedPreferences.setMockInitialValues({
        'bookmarks':
            '[{"url":"https://example.org/old","title":"Old","added":10}]',
      });
      final old = (await Bookmarks.load()).single;
      expect(old.folder, '');
      expect(await Bookmarks.createFolder('Phim'), true);
      expect(await Bookmarks.createFolder('Trống'), true);
      await Bookmarks.rename(old.url, 'Mùa hè');
      await Bookmarks.move(old.url, 'Phim');
      final pages = await Future.wait([
        Bookmarks.add('https://a.example', 'Tập A'),
        Bookmarks.add('https://b.example', 'Tập B'),
      ]);
      expect(pages.every((p) => p.folder == 'Phim'), true);
      await Bookmarks.renameFolder('Phim', 'Yêu thích');
      final renamed = (await Bookmarks.load()).last;
      expect(renamed.matches('YÊU hè'), true);
      expect(renamed.matches('Trống'), false);
      expect(renamed.added, old.added);
      expect(await Bookmarks.folders(), ['Trống', 'Yêu thích']);
      expect(
        (await Bookmarks.add('https://c.example', 'C')).folder,
        'Yêu thích',
      );
      await Bookmarks.deleteFolder('Yêu thích');
      final kept = await Bookmarks.load();
      expect(kept.length, 4);
      expect(kept.every((b) => b.folder.isEmpty), true);
      expect((await Bookmarks.add('https://d.example', 'D')).folder, '');
      expect(await Bookmarks.folders(), ['Trống']);
    },
  );

  testWidgets('a collapsed folder can be searched and a saved page edited', (
    tester,
  ) async {
    await Bookmarks.createFolder('Phim');
    final b = await Bookmarks.add('https://example.org/movie', 'Tập một');
    await Bookmarks.move(b.url, 'Phim');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showBookmarks(ctx),
              child: const Text('Mở kho'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mở kho'));
    await tester.pumpAndSettle();
    expect(find.text('Tập một'), findsNothing);
    await tester.enterText(find.byType(TextField), 'tập');
    await tester.pumpAndSettle();
    expect(find.text('Phim'), findsOneWidget);
    await tester.tap(find.byTooltip('Sửa trang'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Đổi tên'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Tập hai');
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Tập hai'), findsOneWidget);
    await tester.tap(find.byTooltip('Sửa trang'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chuyển vào thư mục…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ngoài cùng').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect((await Bookmarks.load()).single.folder, '');
  });

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
