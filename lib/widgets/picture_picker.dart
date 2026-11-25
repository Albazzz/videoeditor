import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;

import '../services/bookmarks.dart';
import 'common.dart';

typedef CapturePicture = Future<Uint8List?> Function();

/// Holds a draft in memory. Only the caller's Save action persists it.
class PicturePicker extends StatefulWidget {
  const PicturePicker({
    super.key,
    required this.onChanged,
    this.initial,
    this.capture,
    this.onBusy,
  });

  final Uint8List? initial;
  final CapturePicture? capture;
  final ValueChanged<Uint8List?> onChanged;
  final ValueChanged<bool>? onBusy;

  @override
  State<PicturePicker> createState() => _PicturePickerState();
}

class _PicturePickerState extends State<PicturePicker> {
  late Uint8List? _image = widget.initial;
  bool _busy = false;

  Future<void> _pick(String source) async {
    setState(() => _busy = true);
    widget.onBusy?.call(true);
    try {
      Uint8List? bytes;
      if (source == 'page') {
        bytes = await widget.capture!();
        if (bytes == null) return;
      } else {
        final file = await ImagePicker().pickImage(
          source: source == 'camera' ? ImageSource.camera : ImageSource.gallery,
          maxWidth: 960,
          maxHeight: 960,
          imageQuality: 80,
        );
        if (file == null) return;
        bytes = await file.readAsBytes();
        // Camera output is a private cache file, never a Photos/MediaStore save.
        if (source == 'camera') await File(file.path).delete();
      }
      if (!mounted) return;
      setState(() => _image = bytes);
      widget.onChanged(bytes);
    } catch (e) {
      if (mounted) toast(context, 'Không lấy được ảnh: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusy?.call(false);
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Ảnh đại diện'),
      const SizedBox(height: 8),
      if (_image != null)
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.memory(
            _image!,
            height: 112,
            width: double.infinity,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) => const Text('Ảnh không hợp lệ'),
          ),
        ),
      if (_busy) const LinearProgressIndicator(),
      Wrap(
        spacing: 4,
        children: [
          TextButton.icon(
            onPressed: _busy ? null : () => _pick('gallery'),
            icon: const Icon(Icons.photo_library_outlined),
            label: const Text('Chọn ảnh'),
          ),
          if (widget.capture != null)
            TextButton.icon(
              onPressed: _busy ? null : () => _pick('page'),
              icon: const Icon(Icons.screenshot),
              label: const Text('Chụp lại trang'),
            ),
          if (Platform.isAndroid || Platform.isIOS)
            TextButton.icon(
              onPressed: _busy ? null : () => _pick('camera'),
              icon: const Icon(Icons.camera_alt_outlined),
              label: const Text('Chụp ảnh mới'),
            ),
          if (_image != null)
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      setState(() => _image = null);
                      widget.onChanged(null);
                    },
              child: const Text('Bỏ ảnh'),
            ),
        ],
      ),
      Text(
        'Ảnh chụp chỉ lưu trong app, không thêm vào thư viện ảnh.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ],
  );
}

Future<void> editStoredPicture(
  BuildContext context,
  String key, {
  String? fallbackKey,
  CapturePicture? capture,
}) async {
  final initial = await Bookmarks.loadThumb(key, fallbackKey: fallbackKey);
  if (!context.mounted) return;
  var image = initial;
  var busy = false;
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: const Text('Đổi ảnh đại diện'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: PicturePicker(
              initial: initial,
              capture: capture,
              onChanged: (v) => image = v,
              onBusy: (v) => update(() => busy = v),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: busy ? null : () => Navigator.pop(ctx, true),
            child: const Text('Lưu'),
          ),
        ],
      ),
    ),
  );
  if (ok != true) return;
  // An empty private file also suppresses a legacy page-image fallback.
  final name = await Bookmarks.saveThumb(key, image ?? Uint8List(0));
  if (name.isEmpty) throw StateError('Không lưu được ảnh đại diện');
}

/// A reusable picture for lists, with a fallback for old page screenshots.
class StoredPicture extends StatelessWidget {
  const StoredPicture({
    super.key,
    required this.pictureKey,
    this.fallbackKey,
    required this.directory,
    required this.placeholder,
  });
  final String pictureKey;
  final String? fallbackKey, directory;
  final Widget placeholder;

  @override
  Widget build(BuildContext context) {
    final dir = directory;
    File? file;
    if (dir != null) {
      final primary = File(p.join(dir, Bookmarks.thumbName(pictureKey)));
      file = primary.existsSync()
          ? primary
          : fallbackKey == null
          ? null
          : File(p.join(dir, Bookmarks.thumbName(fallbackKey!)));
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        width: 64,
        height: 40,
        child: file != null && file.existsSync() && file.lengthSync() > 0
            ? Image.file(
                file,
                fit: BoxFit.cover,
                cacheWidth: 192,
                errorBuilder: (_, _, _) => placeholder,
              )
            : placeholder,
      ),
    );
  }
}
