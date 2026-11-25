import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/main.dart';
import 'package:video/models/cue.dart';
import 'package:video/screens/saved_pages_screen.dart';
import 'package:video/screens/subtitle_library_screen.dart';
import 'package:video/services/bookmarks.dart';
import 'package:video/services/open_page.dart';
import 'package:video/services/page_translation.dart';
import 'package:video/services/retained_audio.dart';
import 'package:video/services/subtitle_store.dart';
import 'package:video/widgets/bookmarks_sheet.dart';
import 'package:video/widgets/folder_group.dart';

import 'browser_screen_test.dart' show FakeBrowserPlatform;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late Directory supportDir;

  setUpAll(() async {
    supportDir = await Directory.systemTemp.createTemp('folder_support');
  });
  tearDownAll(() => supportDir.delete(recursive: true));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    InAppWebViewPlatform.instance = FakeBrowserPlatform();
    openPageRequest.value = null;
    openPagesRequest.value = null;
    dir = await Directory.systemTemp.createTemp('folder_navigation');
    SubtitleStore.overrideDir = dir;
    PageTranslations.overrideDir = dir;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => supportDir.path,
        );
    // The shared audio store caches its directory future across screens.
    await RetainedAudioStore.instance.list();
    await Bookmarks.createFolder('Phim');
    await Bookmarks.add(
      'https://example.org/1',
      'Tập trong thư mục',
      folder: 'Phim',
    );
    await Bookmarks.add('https://example.org/free', 'Trang chưa xếp');
  });

  tearDown(() async {
    SubtitleStore.overrideDir = null;
    PageTranslations.overrideDir = null;
    openPageRequest.value = null;
    openPagesRequest.value = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await dir.delete(recursive: true);
  });

  Future<void> settleFiles(WidgetTester tester) async {
    // Preferences and file reads alternate across the test's fake clock.
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)),
      );
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  Future<void> openHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(const MaterialApp(home: HomeScreen()));
    await settleFiles(tester);
  }

  testWidgets('saved page round trip keeps folder, search and refreshes data', (
    tester,
  ) async {
    await openHome(tester);
    await tester.tap(find.text('Trang lưu'));
    await settleFiles(tester);
    await tester.tap(find.text('Phim'));
    await settleFiles(tester);
    expect(find.text('Chưa có thư mục'), findsOneWidget);
    final entry = find.ancestor(
      of: find.text('Tập trong thư mục'),
      matching: find.byType(FolderGroupEntry),
    );
    expect(entry, findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'Tập');
    await settleFiles(tester);
    await tester.tap(find.text('Tập trong thư mục'));
    await settleFiles(tester);
    expect(openPageRequest.value, 'https://example.org/1');
    expect(find.byType(SavedPagesScreen), findsNothing);
    // A page saved elsewhere must appear without rebuilding this tab's state.
    await Bookmarks.add('https://example.org/2', 'Tập mới', folder: 'Phim');
    await tester.tap(find.text('Trang lưu'));
    await settleFiles(tester);
    expect(find.text('Tập trong thư mục'), findsOneWidget);
    expect(find.text('Tập mới'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'Tập',
    );
    await tester.enterText(find.byType(TextField).first, '');
    await settleFiles(tester);
    expect(find.text('Tập trong thư mục'), findsOneWidget);
    expect(find.text('Chưa có thư mục'), findsOneWidget);
    expect((await Bookmarks.load()).first.folder, 'Phim');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('opening a saved page keeps the list scroll position on return', (
    tester,
  ) async {
    for (var i = 0; i < 16; i++) {
      await Bookmarks.add(
        'https://example.org/scroll/$i',
        'Cuộn $i',
        folder: 'Phim',
      );
    }
    await openHome(tester);
    await tester.tap(find.text('Trang lưu'));
    await settleFiles(tester);
    await tester.tap(find.text('Phim'));
    await settleFiles(tester);
    final list = find.byKey(const PageStorageKey('bookmark-list'));
    await tester.drag(list, const Offset(0, -400));
    await settleFiles(tester);
    ScrollPosition position() => tester
        .state<ScrollableState>(
          find.descendant(of: list, matching: find.byType(Scrollable)).first,
        )
        .position;
    final before = position().pixels;
    expect(before, greaterThan(0));
    await tester.tap(
      find
          .byWidgetPredicate(
            (w) =>
                w is ListTile &&
                w.title is Text &&
                ((w.title as Text).data?.startsWith('Cuộn ') ?? false),
          )
          .hitTestable()
          .first,
    );
    await settleFiles(tester);
    await tester.tap(find.text('Trang lưu'));
    await settleFiles(tester);
    expect(position().pixels, closeTo(before, 1));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('subtitle round trip keeps the folder open', (tester) async {
    await tester.runAsync(() async {
      for (final id in ['inside', 'outside']) {
        await SubtitleStore.save(
          SavedSubs(
            id: id,
            title: id == 'inside' ? 'Phụ đề trong thư mục' : 'Phụ đề chưa xếp',
            page: 'https://example.org/$id',
            language: 'ja',
            updated: DateTime(2026),
            cues: const [Cue(start: 0, end: 1, text: 'Xin chào')],
            covered: const [(0, 1)],
            complete: true,
          ),
        );
      }
      await Bookmarks.moveSubtitles(['inside'], 'Phim');
    });
    await openHome(tester);
    await tester.tap(find.text('Phụ đề'));
    await settleFiles(tester);
    await tester.tap(find.text('Phim'));
    await settleFiles(tester);
    expect(find.text('Chưa phân loại'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Phụ đề trong thư mục'),
        matching: find.byType(FolderGroupEntry),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text('Phụ đề trong thư mục'));
    await settleFiles(tester);
    expect(openPageRequest.value, 'https://example.org/inside');
    expect(find.byType(SubtitleLibraryScreen), findsNothing);
    await tester.tap(find.text('Phụ đề'));
    await settleFiles(tester);
    expect(find.text('Phụ đề trong thư mục'), findsOneWidget);
    expect(find.text('Phụ đề chưa xếp'), findsOneWidget);
    expect((await Bookmarks.subtitleFolders())['inside'], 'Phim');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final subtitles in [false, true]) {
    testWidgets(
      '${subtitles ? 'subtitles' : 'saved pages'} selection keeps scroll and folders until explicitly opened',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.runAsync(() async {
          await Bookmarks.createFolder('A đang đóng');
          final inFolder = <String>[];
          for (var i = 0; i < 18; i++) {
            final closed = i == 17;
            final id = 'selection-$i';
            final title = closed
                ? 'Nội dung chỉ hiện khi tự mở'
                : 'Danh sách $i với tên video dài để kiểm tra bố cục khi chọn nhiều';
            if (subtitles) {
              await SubtitleStore.save(
                SavedSubs(
                  id: id,
                  title: title,
                  page: 'https://example.org/$id',
                  language: 'ja',
                  updated: DateTime(2026, 11, 24, 0, i),
                  cues: const [Cue(start: 0, end: 1, text: 'Xin chào')],
                  covered: const [(0, 400)],
                  duration: 1000,
                ),
              );
              if (closed) {
                await Bookmarks.moveSubtitles([id], 'A đang đóng');
              } else {
                inFolder.add(id);
              }
            } else {
              await Bookmarks.add(
                'https://example.org/$id',
                title,
                folder: closed ? 'A đang đóng' : 'Phim',
              );
            }
          }
          if (subtitles) await Bookmarks.moveSubtitles(inFolder, 'Phim');
        });
        await tester.pumpWidget(
          MaterialApp(
            home: subtitles
                ? const SubtitleLibraryScreen()
                : Scaffold(
                    body: BookmarksView(
                      onOpen: (_) => fail('Selection must not open a page'),
                    ),
                  ),
          ),
        );
        await settleFiles(tester);
        for (var i = 0; i < 10 && find.text('Phim').evaluate().isEmpty; i++) {
          await settleFiles(tester);
        }
        await tester.tap(find.text('Phim'));
        await settleFiles(tester);
        final list = find.byKey(
          PageStorageKey(subtitles ? 'subtitle-library-list' : 'bookmark-list'),
        );
        await tester.drag(list, const Offset(0, -600));
        await tester.pumpAndSettle();
        ScrollPosition position() => tester
            .state<ScrollableState>(
              find
                  .descendant(of: list, matching: find.byType(Scrollable))
                  .first,
            )
            .position;
        final visible = find
            .byWidgetPredicate(
              (w) =>
                  w is ListTile &&
                  w.title is Text &&
                  ((w.title as Text).data?.startsWith('Danh sách ') ?? false),
            )
            .hitTestable()
            .first;
        final title = (tester.widget<ListTile>(visible).title as Text).data!;
        final target = find
            .ancestor(of: find.text(title), matching: find.byType(ListTile))
            .first;
        final before = position().pixels;
        final top = tester.getTopLeft(target).dy;
        expect(before, greaterThan(0));
        await tester.longPress(target);
        await tester.pumpAndSettle();
        expect(find.text('Đã chọn 1'), findsOneWidget);
        expect(position().pixels, closeTo(before, 1));
        expect(tester.getTopLeft(target).dy, closeTo(top, 1));
        await tester.tap(find.byTooltip('Thôi chọn'));
        await tester.pumpAndSettle();
        expect(position().pixels, closeTo(before, 1));
        expect(tester.getTopLeft(target).dy, closeTo(top, 1));

        await tester.longPress(target);
        await tester.pumpAndSettle();
        await tester.drag(list, const Offset(0, 2000));
        await tester.pumpAndSettle();
        Finder folder(String title) => find.byWidgetPredicate(
          (w) => w is FolderGroupHeader && w.title == title,
        );
        expect(
          tester.widget<FolderGroupHeader>(folder('A đang đóng')).expanded,
          false,
        );
        await tester.tap(find.text('A đang đóng'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<FolderGroupHeader>(folder('A đang đóng')).expanded,
          true,
        );
        await tester.tap(find.text('Nội dung chỉ hiện khi tự mở'));
        await tester.pumpAndSettle();
        expect(find.text('Đã chọn 2'), findsOneWidget);
        await tester.tap(find.byTooltip('Thôi chọn'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<FolderGroupHeader>(folder('A đang đóng')).expanded,
          true,
        );
        await tester.scrollUntilVisible(
          folder('Phim'),
          100,
          scrollable: find
              .descendant(of: list, matching: find.byType(Scrollable))
              .first,
        );
        expect(tester.widget<FolderGroupHeader>(folder('Phim')).expanded, true);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('reopening bookmarks sheet restores expanded folders', (
    tester,
  ) async {
    String? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => opened = await showBookmarks(context),
              child: const Text('Mở danh sách'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mở danh sách'));
    await settleFiles(tester);
    await tester.tap(find.text('Phim'));
    await settleFiles(tester);
    await tester.tap(find.text('Tập trong thư mục'));
    await settleFiles(tester);
    expect(opened, 'https://example.org/1');
    await tester.tap(find.text('Mở danh sách'));
    await settleFiles(tester);
    expect(find.text('Tập trong thư mục'), findsOneWidget);
    expect(find.text('Chưa có thư mục'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
