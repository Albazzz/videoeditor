import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/widgets/bookmarks_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/services/bookmarks.dart';
import 'dart:io';

import 'package:video/models/cue.dart';
import 'package:video/services/subtitle_store.dart';

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
      // The folder is chosen when saving; the last one is only offered.
      expect(await Bookmarks.lastFolder(), 'Phim');
      final pages = await Future.wait([
        Bookmarks.add('https://a.example', 'Tập A', folder: 'Phim'),
        Bookmarks.add('https://b.example', 'Tập B', folder: 'Phim'),
      ]);
      expect(pages.every((p) => p.folder == 'Phim'), true);
      await Bookmarks.renameFolder('Phim', 'Yêu thích');
      final renamed = (await Bookmarks.load()).last;
      expect(renamed.matches('YÊU hè'), true);
      expect(renamed.matches('Trống'), false);
      expect(renamed.added, old.added);
      expect(await Bookmarks.folders(), ['Trống', 'Yêu thích']);
      expect(await Bookmarks.lastFolder(), 'Yêu thích');
      expect(
        (await Bookmarks.add(
          'https://c.example',
          'C',
          folder: await Bookmarks.lastFolder(),
        )).folder,
        'Yêu thích',
      );
      expect(
        (await Bookmarks.add('https://x.example', 'X')).folder,
        '',
        reason: 'nothing is filed away without being asked',
      );
      await Bookmarks.remove('https://x.example');
      await Bookmarks.deleteFolder('Yêu thích');
      final kept = await Bookmarks.load();
      expect(kept.length, 4);
      expect(kept.every((b) => b.folder.isEmpty), true);
      expect((await Bookmarks.add('https://d.example', 'D')).folder, '');
      expect(await Bookmarks.folders(), ['Trống']);
    },
  );

  test('subtitles share the folders of saved pages and follow renames', () async {
    await Bookmarks.createFolder('Hàn');
    await Bookmarks.moveSubtitles(['s1', 's2'], 'Phim lẻ');
    expect(await Bookmarks.folders(), ['Hàn', 'Phim lẻ']);
    await Bookmarks.renameFolder('Phim lẻ', 'Lẻ');
    expect(await Bookmarks.subtitleFolders(), {'s1': 'Lẻ', 's2': 'Lẻ'});
    await Bookmarks.moveSubtitles(['s2'], '');
    await Bookmarks.deleteFolder('Lẻ');
    expect(await Bookmarks.subtitleFolders(), isEmpty);
    expect(await Bookmarks.folders(), ['Hàn']);
  });

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
    // ✕ empties the old name in one tap.
    await tester.tap(find.byTooltip('Xoá hết').last);
    await tester.pump();
    expect(
      tester.widget<TextField>(find.byType(TextField).last).controller!.text,
      '',
    );
    await tester.enterText(find.byType(TextField).last, 'Tập hai');
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

  testWidgets('a saved page with subtitles carries the mark', (tester) async {
    final dir = (await tester.runAsync(
      () => Directory.systemTemp.createTemp('marks'),
    ))!;
    SubtitleStore.overrideDir = dir;
    addTearDown(() {
      SubtitleStore.overrideDir = null;
      dir.deleteSync(recursive: true);
    });
    await tester.runAsync(() async {
      await Bookmarks.add('https://phim.example/1', 'Có dịch');
      await Bookmarks.add('https://phim.example/2', 'Chưa dịch');
      await SubtitleStore.save(
        SavedSubs(
          id: 'x',
          title: 'Phim',
          page: 'https://phim.example/1',
          language: 'ja',
          updated: DateTime(2026),
          cues: const [Cue(start: 1, end: 2, text: 'Chào', source: 'やあ')],
          covered: const [(0, 500)],
          duration: 1000,
        ),
      );
      // Real file reads finish outside the widget test's fake clock.
      await SubtitleStore.pageMarks();
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: BookmarksView(onOpen: (_) {})),
      ),
    );
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
    }
    expect(find.text('Có phụ đề · 50%'), findsOneWidget);
    expect(find.text('Có dịch'), findsOneWidget);
    expect(find.text('Chưa dịch'), findsOneWidget);
  });

  testWidgets('a long press picks pages; picked pages go together', (
    tester,
  ) async {
    await Bookmarks.add('https://a.example/1', 'Một');
    await Bookmarks.add('https://b.example/2', 'Hai');
    await Bookmarks.add('https://c.example/3', 'Ba');
    final opened = <String>[];
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: BookmarksView(onOpen: opened.add))),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Một'));
    await tester.pump();
    expect(find.text('Đã chọn 1'), findsOneWidget);
    // While picking, a tap picks instead of opening.
    await tester.tap(find.text('Hai'));
    await tester.pump();
    expect(find.text('Đã chọn 2'), findsOneWidget);
    expect(opened, isEmpty);
    await tester.tap(find.byTooltip('Xoá'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Xoá'));
    await tester.pumpAndSettle();
    expect((await Bookmarks.load()).map((b) => b.title), ['Ba']);
    expect(find.text('Đã chọn 2'), findsNothing);
  });

  testWidgets('saving asks for the name and folder first', (tester) async {
    await Bookmarks.createFolder('Phim Trung');
    (String, String)? picked;
    var asked = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () async {
                picked = await askBookmarkPlace(ctx, 'Tập 1');
                asked = true;
              },
              child: const Text('Lưu'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    expect(find.text('Lưu trang vào đâu?'), findsOneWidget);
    expect(find.text('Ngoài cùng'), findsOneWidget);
    // A new folder can be made right there and is then chosen.
    await tester.tap(find.text('Thư mục mới…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Hàn');
    await tester.tap(find.text('Lưu').last);
    await tester.pumpAndSettle();
    expect(find.text('Hàn'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Tập 1'),
      'Tập 1 - bản đẹp',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Lưu'));
    await tester.pumpAndSettle();
    expect(picked, ('Tập 1 - bản đẹp', 'Hàn'));

    // Cancelling saves nothing.
    picked = null;
    asked = false;
    await tester.tap(find.text('Lưu'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Huỷ'));
    await tester.pumpAndSettle();
    expect(asked, isTrue);
    expect(picked, isNull);
  });
}
