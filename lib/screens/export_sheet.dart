import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/cue.dart';
import '../services/exporter.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';

/// Trim, change speed (0.5x–2.5x) and burn subtitles into a new video file.
class ExportSheet extends StatefulWidget {
  const ExportSheet({
    super.key,
    required this.item,
    required this.duration,
    required this.cues,
    required this.subtitlesComplete,
    this.initialSpeed = 1,
  });

  final VideoItem item;
  final double duration;
  final List<Cue> cues;

  /// False while subtitles are still being generated.
  final bool subtitlesComplete;
  final double initialSpeed;

  @override
  State<ExportSheet> createState() => _ExportSheetState();
}

class _ExportSheetState extends State<ExportSheet> {
  late RangeValues _range = RangeValues(0, widget.duration);
  late double _speed = widget.initialSpeed;
  late bool _burn = widget.cues.isNotEmpty;
  double? _progress;
  String? _message;

  Future<void> _run() async {
    setState(() {
      _progress = 0;
      _message = null;
    });
    final name = '${p.basenameWithoutExtension(widget.item.name)}_edit.mp4';
    final output = await VideoLibrary.newOutputPath(name);
    final error = await exportVideo(
      input: widget.item.file.path,
      output: output,
      from: _range.start,
      to: _range.end,
      speed: _speed,
      burnCues: _burn ? widget.cues : const [],
      onProgress: (v) {
        if (mounted) setState(() => _progress = v);
      },
    );
    if (!mounted) return;
    setState(() {
      _progress = null;
      _message = error == null
          ? 'Đã lưu "${p.basename(output)}" vào Thư viện'
          : 'Xuất thất bại: $error';
    });
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    final outLength = (_range.end - _range.start) / _speed;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          20,
          16,
          20,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Chỉnh sửa và xuất',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'Cắt: ${formatTime(_range.start)} → ${formatTime(_range.end)}',
            ),
            RangeSlider(
              values: _range,
              max: widget.duration,
              labels: RangeLabels(
                formatTime(_range.start),
                formatTime(_range.end),
              ),
              onChanged: busy
                  ? null
                  : (v) {
                      if (v.end - v.start >= 1) setState(() => _range = v);
                    },
            ),
            Text('Tốc độ: ${speedLabel(_speed)}'),
            Slider(
              value: _speed,
              min: kMinSpeed,
              max: kMaxSpeed,
              divisions: ((kMaxSpeed - kMinSpeed) / 0.25).round(),
              label: speedLabel(_speed),
              onChanged: busy ? null : (v) => setState(() => _speed = v),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Gắn phụ đề vào video'),
              subtitle: Text(
                widget.cues.isEmpty
                    ? 'Chưa có phụ đề: bấm nút CC khi xem để tạo'
                    : widget.subtitlesComplete
                    ? '${widget.cues.length} dòng phụ đề'
                    : 'Phụ đề chưa tạo xong, mới có ${widget.cues.length} dòng',
              ),
              value: _burn,
              onChanged: busy || widget.cues.isEmpty
                  ? null
                  : (v) => setState(() => _burn = v),
            ),
            Text(
              'Video xuất ra dài khoảng ${formatTime(outLength)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            if (busy) ...[
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(
                'Đang xuất ${(_progress! * 100).toStringAsFixed(0)}%… '
                'giữ app mở',
              ),
            ],
            if (_message != null) Text(_message!),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: busy ? null : _run,
                icon: const Icon(Icons.movie_creation_outlined),
                label: const Text('Xuất video'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
