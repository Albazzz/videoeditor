import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/widgets/crop_picture.dart';

Future<Uint8List> _twoColors() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 16, 16),
    Paint()..color = Colors.red,
  );
  canvas.drawRect(
    const Rect.fromLTWH(16, 0, 16, 16),
    Paint()..color = Colors.blue,
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(32, 16);
  picture.dispose();
  try {
    return (await image.toByteData(
      format: ui.ImageByteFormat.png,
    ))!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

void main() {
  testWidgets(
    'dragging crops actual image pixels and cancellation keeps the draft',
    (tester) async {
      final bytes = await tester.runAsync(_twoColors);
      Uint8List? selected;
      var finished = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  selected = await cropPicture(context, bytes!);
                  finished = true;
                },
                child: const Text('Chụp'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Chụp'));
      for (
        var i = 0;
        i < 30 && find.text('Khoanh vùng ảnh đại diện').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      final area = tester.getRect(find.byKey(const Key('picture-crop-area')));
      // A 2:1 image is fitted in the center; select its red left quarter.
      final imageHeight = area.width / 2;
      final top = area.center.dy - imageHeight / 2;
      final start = Offset(
        area.left + area.width * .05,
        top + imageHeight * .1,
      );
      await tester.timedDragFrom(
        start,
        Offset(area.width * .2, imageHeight * .8),
        const Duration(milliseconds: 400),
      );
      await tester.pump();
      await tester.tap(find.text('Dùng vùng đã chọn'));
      for (var i = 0; i < 30 && !finished; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      expect(selected, isNotNull);
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(selected!);
        final frame = await codec.getNextFrame();
        codec.dispose();
        final image = frame.image;
        expect(image.width, lessThan(16));
        expect(image.height, lessThanOrEqualTo(16));
        final raw = await image.toByteData();
        // Every output pixel is red: the blue half was actually removed.
        for (var i = 0; i < raw!.lengthInBytes; i += 4) {
          expect(raw.getUint8(i), 244);
          expect(raw.getUint8(i + 2), 54);
        }
        image.dispose();
      });

      finished = false;
      await tester.tap(find.text('Chụp'));
      for (
        var i = 0;
        i < 30 && find.text('Khoanh vùng ảnh đại diện').evaluate().isEmpty;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Huỷ'));
      await tester.pumpAndSettle();
      expect(finished, true);
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
