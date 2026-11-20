import 'package:flutter/material.dart';

import '../models/cue.dart';
import '../services/app_settings.dart';
import '../services/model_store.dart';
import '../services/subtitle_store.dart';

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

/// The video's timeline: stretches that have subtitles are filled in,
/// with a mark where the viewer is.
class CoverageBar extends StatelessWidget {
  const CoverageBar({
    super.key,
    required this.covered,
    required this.duration,
    this.position,
    this.done = false,
    this.height = 6,
  });

  final List<(double, double)> covered;
  final double duration;
  final double? position;
  final bool done;
  final double height;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: height + 4,
      width: double.infinity,
      child: CustomPaint(
        painter: _CoveragePainter(
          covered: covered,
          duration: duration,
          position: position,
          track: scheme.onSurface.withValues(alpha: 0.15),
          fill: done ? Colors.green : scheme.primary,
          mark: scheme.onSurface,
          height: height,
        ),
      ),
    );
  }
}

class _CoveragePainter extends CustomPainter {
  _CoveragePainter({
    required this.covered,
    required this.duration,
    required this.position,
    required this.track,
    required this.fill,
    required this.mark,
    required this.height,
  });

  final List<(double, double)> covered;
  final double duration;
  final double? position;
  final Color track;
  final Color fill;
  final Color mark;
  final double height;

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - height) / 2;
    final bar = RRect.fromLTRBR(
      0,
      top,
      size.width,
      top + height,
      Radius.circular(height / 2),
    );
    canvas.drawRRect(bar, Paint()..color = track);
    if (duration <= 0) return;
    double x(double t) => (t / duration).clamp(0.0, 1.0) * size.width;
    canvas
      ..save()
      ..clipRRect(bar);
    final paint = Paint()..color = fill;
    for (final r in covered) {
      // At least a sliver, so a short stretch still shows.
      final left = x(r.$1);
      final right = x(r.$2) < left + 1.5 ? left + 1.5 : x(r.$2);
      canvas.drawRect(Rect.fromLTRB(left, top, right, top + height), paint);
    }
    canvas.restore();
    final p = position;
    if (p != null) {
      final px = x(p);
      canvas.drawRRect(
        RRect.fromLTRBR(
          px - 1.5,
          0,
          px + 1.5,
          size.height,
          const Radius.circular(1.5),
        ),
        Paint()..color = mark,
      );
    }
  }

  @override
  bool shouldRepaint(_CoveragePainter old) =>
      old.covered != covered ||
      old.duration != duration ||
      old.position != position ||
      old.fill != fill;
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
    final scale = appSettings.subScale;
    final bg = appSettings.subBg;
    // Without a box, an outline keeps the text readable.
    final shadows = bg > 0.05
        ? null
        : const [
            Shadow(blurRadius: 3),
            Shadow(offset: Offset(1, 1)),
            Shadow(offset: Offset(-1, -1)),
          ];
    return IgnorePointer(
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: bg),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showSource)
              Text(
                c.source,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13 * scale,
                  shadows: shadows,
                ),
              ),
            Text(
              c.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 18 * scale,
                height: 1.25,
                fontWeight: FontWeight.w500,
                shadows: shadows,
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

/// "Đủ cả phim", "Đã làm 42% (12:30/30:00)" or "Đã làm 12:30".
String subtitleProgressLabel({
  required List<(double, double)> covered,
  required double duration,
  bool reachedEnd = false,
}) {
  if (coversWholeVideo(covered, duration, reachedEnd: reachedEnd)) {
    return 'Đủ cả phim';
  }
  final done = coveredSeconds(covered);
  if (duration <= 0) return 'Đã làm ${formatTime(done)}';
  final pct = (done / duration * 100).clamp(0, 100).floor();
  return 'Đã làm $pct% (${formatTime(done)}/${formatTime(duration)})';
}

/// A text box with a ✕ that empties it in one tap (a new name often
/// starts from nothing).
class ClearableField extends StatelessWidget {
  const ClearableField({
    super.key,
    required this.controller,
    this.label,
    this.hint,
    this.autofocus = false,
    this.minLines,
    this.maxLines = 1,
    this.onSubmitted,
    this.onChanged,
    this.prefixIcon,
  });

  final TextEditingController controller;
  final String? label;
  final String? hint;
  final bool autofocus;
  final int? minLines;
  final int? maxLines;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final Widget? prefixIcon;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: controller,
    builder: (context, value, _) => TextField(
      controller: controller,
      autofocus: autofocus,
      minLines: minLines,
      maxLines: maxLines,
      onSubmitted: onSubmitted,
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: prefixIcon,
        suffixIcon: value.text.isEmpty
            ? null
            : IconButton(
                tooltip: 'Xoá hết',
                icon: const Icon(Icons.cancel),
                onPressed: () {
                  controller.clear();
                  onChanged?.call('');
                },
              ),
      ),
    ),
  );
}

/// Asks for a line of text (a name), with ✕ to clear it. Null when
/// cancelled; the trimmed text otherwise.
Future<String?> askText(
  BuildContext context,
  String title, {
  String initial = '',
  String? label,
  int lines = 1,
  String action = 'Lưu',
}) => showDialog<String>(
  context: context,
  builder: (_) => _TextDialog(
    title: title,
    initial: initial,
    label: label,
    lines: lines,
    action: action,
  ),
);

class _TextDialog extends StatefulWidget {
  const _TextDialog({
    required this.title,
    required this.initial,
    required this.label,
    required this.lines,
    required this.action,
  });
  final String title, initial, action;
  final String? label;
  final int lines;

  @override
  State<_TextDialog> createState() => _TextDialogState();
}

class _TextDialogState extends State<_TextDialog> {
  late final _text = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: ClearableField(
      controller: _text,
      label: widget.label,
      autofocus: true,
      minLines: widget.lines,
      maxLines: widget.lines == 1 ? 1 : widget.lines + 2,
      onSubmitted: widget.lines == 1
          ? (v) => Navigator.pop(context, v.trim())
          : null,
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Huỷ'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, _text.text.trim()),
        child: Text(widget.action),
      ),
    ],
  );
}
