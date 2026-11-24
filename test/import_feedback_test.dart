import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/bookmarks.dart';
import 'package:video/services/translator.dart';
import 'package:video/widgets/bookmarks_sheet.dart';
import 'package:video/widgets/subtitle_import.dart';

class _PartialTranslator extends PassthroughTranslator {
  final asked = <List<String>>[];
  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int)? onProgress,
  }) async {
    asked.add(List.of(lines));
    // A short partial response must preserve successes and expose Retry.
    return asked.length == 1 ? ['Xin chào'] : ['Thế giới'];
  }
}

void main() {
  test(
    'page and subtitle pictures persist separately in app storage',
    () async {
      final support = await Directory.systemTemp.createTemp('pictures_');
      Bookmarks.overrideThumbDir = support;
      try {
        const page = 'https://example.org/watch';
        final subtitle = Bookmarks.subtitlePictureKey('video-1');
        final pageBytes = Uint8List.fromList([1, 2, 3]);
        final subBytes = Uint8List.fromList([4, 5, 6]);
        await Bookmarks.saveThumb(page, pageBytes);
        await Bookmarks.saveThumb(subtitle, subBytes);
        expect(await Bookmarks.loadThumb(page), pageBytes);
        expect(await Bookmarks.loadThumb(subtitle), subBytes);
        // Removing a subtitle image must not change the saved page's picture.
        await Bookmarks.saveThumb(subtitle, Uint8List(0));
        expect(await Bookmarks.loadThumb(subtitle), isNull);
        expect(await Bookmarks.loadThumb(subtitle, fallbackKey: page), isNull);
        expect(await Bookmarks.loadThumb(page), pageBytes);
        expect((await Bookmarks.thumbDir())!.parent.path, support.path);
      } finally {
        Bookmarks.overrideThumbDir = null;
        await support.delete(recursive: true);
      }
    },
  );

  testWidgets('retrying an import sends only missing unique lines', (
    tester,
  ) async {
    final engine = _PartialTranslator();
    List<Cue>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await translateImportedCues(
                  context,
                  const [
                    Cue(start: 0, end: 1, text: 'Hello'),
                    Cue(start: 2, end: 3, text: 'World'),
                    Cue(start: 4, end: 5, text: 'Hello'),
                  ],
                  'en',
                  translator: engine,
                );
              },
              child: const Text('Nhập'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Nhập'));
    await tester.pumpAndSettle();
    expect(result, isNull);
    expect(find.text('Thử lại'), findsOneWidget);
    expect(engine.asked, [
      ['Hello', 'World'],
    ]);
    await tester.tap(find.text('Thử lại'));
    await tester.pumpAndSettle();
    expect(engine.asked, [
      ['Hello', 'World'],
      ['World'],
    ]);
    expect(result!.map((c) => c.text), ['Xin chào', 'Thế giới', 'Xin chào']);
    expect(result!.map((c) => c.source), ['Hello', 'World', 'Hello']);
    expect(result!.map((c) => c.start), [0, 2, 4]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a picture can be retaken; cancelling never commits the draft', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final png = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
    var shots = 0, commits = 0;
    Uint8List? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                await askBookmarkPlace(
                  context,
                  'Trang',
                  capture: () async {
                    shots++;
                    return png;
                  },
                  onPicture: (image) {
                    commits++;
                    saved = image;
                  },
                );
              },
              child: const Text('Mở'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chụp lại trang'));
    await tester.pumpAndSettle();
    expect(find.byType(Image), findsOneWidget);
    expect(commits, 0);
    await tester.tap(find.text('Huỷ'));
    await tester.pumpAndSettle();
    expect(commits, 0);
    await tester.tap(find.text('Mở'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chụp lại trang'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Chụp lại trang'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Lưu'));
    await tester.pumpAndSettle();
    expect(shots, 3);
    expect(commits, 1);
    expect(saved, png);
    expect(tester.takeException(), isNull);
  });
}
