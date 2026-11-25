import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'common.dart';

/// Crop in memory; cancellation leaves the existing thumbnail untouched.
Future<Uint8List?> cropPicture(BuildContext context, Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  final image = frame.image;
  try {
    if (!context.mounted) return null;
    final route = MaterialPageRoute<Uint8List>(
      builder: (_) => _CropPicture(image: image),
    );
    final result = await Navigator.of(context).push<Uint8List>(route);
    // The route still paints while its closing animation runs.
    await route.completed;
    return result;
  } finally {
    image.dispose();
  }
}

class _CropPicture extends StatefulWidget {
  const _CropPicture({required this.image});
  final ui.Image image;
  @override
  State<_CropPicture> createState() => _CropPictureState();
}

class _CropPictureState extends State<_CropPicture> {
  Rect _selection = const Rect.fromLTWH(0, 0, 1, 1);
  Offset? _anchor;
  bool _saving = false;

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final image = widget.image;
      final left = (_selection.left * image.width).floor();
      final top = (_selection.top * image.height).floor();
      final width = (_selection.right * image.width).ceil() - left;
      final height = (_selection.bottom * image.height).ceil() - top;
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawImageRect(
        image,
        Rect.fromLTWH(
          left.toDouble(),
          top.toDouble(),
          width.toDouble(),
          height.toDouble(),
        ),
        Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
        Paint(),
      );
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(width, height);
      picture.dispose();
      try {
        final data = await cropped.toByteData(format: ui.ImageByteFormat.png);
        if (mounted && data != null) {
          Navigator.pop(
            context,
            data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          );
        }
      } finally {
        cropped.dispose();
      }
    } catch (e) {
      if (mounted) toast(context, 'Không cắt được ảnh: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Khoanh vùng ảnh đại diện'),
      actions: [
        TextButton(
          onPressed: _saving
              ? null
              : () => setState(
                  () => _selection = const Rect.fromLTWH(0, 0, 1, 1),
                ),
          child: const Text('Chọn toàn ảnh'),
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Kéo để khoanh vùng cần chụp. Kéo lại để chọn vùng khác.',
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final size = constraints.biggest;
                final fitted = applyBoxFit(
                  BoxFit.contain,
                  Size(
                    widget.image.width.toDouble(),
                    widget.image.height.toDouble(),
                  ),
                  size,
                );
                final bounds = Alignment.center.inscribe(
                  fitted.destination,
                  Offset.zero & size,
                );
                Offset normalized(Offset point) => Offset(
                  ((point.dx - bounds.left) / bounds.width).clamp(0, 1),
                  ((point.dy - bounds.top) / bounds.height).clamp(0, 1),
                );
                return GestureDetector(
                  key: const Key('picture-crop-area'),
                  dragStartBehavior: DragStartBehavior.down,
                  behavior: HitTestBehavior.opaque,
                  onPanStart: _saving
                      ? null
                      : (details) {
                          _anchor = normalized(details.localPosition);
                          setState(
                            () => _selection = Rect.fromPoints(
                              _anchor!,
                              _anchor!,
                            ),
                          );
                        },
                  onPanUpdate: _saving
                      ? null
                      : (details) {
                          setState(
                            () => _selection = Rect.fromPoints(
                              _anchor!,
                              normalized(details.localPosition),
                            ),
                          );
                        },
                  child: CustomPaint(
                    size: size,
                    painter: _CropPainter(widget.image, bounds, _selection),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Huỷ'),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed:
                      _saving ||
                          _selection.width * widget.image.width < 1 ||
                          _selection.height * widget.image.height < 1
                      ? null
                      : _save,
                  child: Text(_saving ? 'Đang cắt…' : 'Dùng vùng đã chọn'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.bounds, this.selection);
  final ui.Image image;
  final Rect bounds, selection;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      bounds,
      Paint(),
    );
    final selected = Rect.fromLTRB(
      bounds.left + selection.left * bounds.width,
      bounds.top + selection.top * bounds.height,
      bounds.left + selection.right * bounds.width,
      bounds.top + selection.bottom * bounds.height,
    );
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRect(selected);
    canvas.drawPath(shade, Paint()..color = Colors.black54);
    canvas.drawRect(
      selected,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      image != old.image || bounds != old.bounds || selection != old.selection;
}
