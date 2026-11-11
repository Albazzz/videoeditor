import 'package:flutter/material.dart';

import '../models/cue.dart';
import '../services/app_settings.dart';
import '../services/model_store.dart';

void toast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}

String formatTime(double seconds) {
  final s = seconds.isFinite && seconds > 0 ? seconds.floor() : 0;
  String two(int v) => v.toString().padLeft(2, '0');
  final h = s ~/ 3600;
  return h > 0
      ? '$h:${two(s ~/ 60 % 60)}:${two(s % 60)}'
      : '${s ~/ 60}:${two(s % 60)}';
}

/// Asks for a key. Returns null when cancelled.
Future<String?> askKey(
  BuildContext context,
  String title, {
  String label = 'Key',
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        obscureText: true,
        decoration: InputDecoration(labelText: label),
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Huỷ'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}

/// Makes sure the speech models are on the device, downloading them (with a
/// progress dialog) the first time. Returns false if the user backs out.
Future<bool> ensureModels(BuildContext context) async {
  if (await ModelStore.isReady()) return true;
  if (!context.mounted) return false;
  final mb = (ModelStore.totalBytes / 1e6).round();
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ModelDialog(megabytes: mb),
      ) ??
      false;
}

class _ModelDialog extends StatefulWidget {
  const _ModelDialog({required this.megabytes});
  final int megabytes;

  @override
  State<_ModelDialog> createState() => _ModelDialogState();
}

class _ModelDialogState extends State<_ModelDialog> {
  double? _progress;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _progress = 0;
      _error = null;
    });
    try {
      await ModelStore.download((v) {
        if (mounted && (v - (_progress ?? 0) > 0.005 || v >= 1)) {
          setState(() => _progress = v);
        }
      });
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _progress = null;
          _error = '$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    return AlertDialog(
      title: const Text('Tải bộ nhận dạng giọng nói'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Cần tải một lần khoảng ${widget.megabytes} MB. '
            'Sau đó nhận dạng chạy ngay trên máy, không cần mạng.',
          ),
          if (busy) ...[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: _progress),
            const SizedBox(height: 8),
            Text('${(_progress! * 100).toStringAsFixed(0)}%'),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        if (!busy)
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Để sau'),
          ),
        if (!busy)
          FilledButton(onPressed: _download, child: const Text('Tải về')),
      ],
    );
  }
}

/// The subtitle line drawn over a video.
class SubtitleText extends StatelessWidget {
  const SubtitleText({super.key, required this.cue});
  final Cue? cue;

  @override
  Widget build(BuildContext context) {
    final c = cue;
    if (c == null || c.text.trim().isEmpty) return const SizedBox.shrink();
    final showSource =
        appSettings.showSource && c.source.isNotEmpty && c.source != c.text;
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.65),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSource)
              Text(
                c.source,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
            Text(
              c.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                height: 1.25,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Speeds offered everywhere, up to 2.5x.
const kSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5];

String speedLabel(double s) =>
    '${s.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '')}x';
