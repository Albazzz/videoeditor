import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';
import 'audio_feed.dart';

const double kMaxSpeed = 2.5;
const double kMinSpeed = 0.5;

/// Builds the ffmpeg arguments for trim + speed + burned-in subtitles in a
/// single encode.
List<String> buildExportArgs({
  required String input,
  required String output,
  required double from,
  required double to,
  required double speed,
  String? srtPath,
  String? fontsDir,
  bool hardwareEncoder = false,
}) {
  final video = <String>[
    // Subtitles are timed on the trimmed clip, so burn before retiming.
    if (srtPath != null)
      "subtitles='${_escape(srtPath)}'"
          "${fontsDir == null ? '' : ":fontsdir='${_escape(fontsDir)}'"}"
          ":force_style='FontName=Noto Sans,FontSize=20,Outline=1.5,MarginV=28'",
    if (speed != 1) 'setpts=PTS/${speed.toStringAsFixed(3)}',
  ];
  return [
    '-y',
    '-ss',
    from.toStringAsFixed(3),
    '-to',
    to.toStringAsFixed(3),
    '-i',
    input,
    if (video.isNotEmpty) ...['-vf', video.join(',')],
    if (speed != 1) ...['-af', 'atempo=${speed.toStringAsFixed(3)}'],
    '-c:v',
    hardwareEncoder ? 'h264_videotoolbox' : 'libx264',
    if (hardwareEncoder) ...[
      '-b:v',
      '6M',
    ] else ...[
      '-crf',
      '21',
      '-preset',
      'veryfast',
    ],
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-b:a',
    '160k',
    '-movflags',
    '+faststart',
    output,
  ];
}

/// Escapes a path for use inside an ffmpeg filter argument.
String _escape(String path) =>
    path.replaceAll(r'\', '/').replaceAll(':', r'\:').replaceAll("'", r"\'");

/// Returns null on success, otherwise an error message.
Future<String?> exportVideo({
  required String input,
  required String output,
  required double from,
  required double to,
  required double speed,
  List<Cue> burnCues = const [],
  void Function(double fraction)? onProgress,
}) async {
  String? srtPath;
  String? fontsDir;
  final tmp = await getTemporaryDirectory();
  final work = await Directory(p.join(tmp.path, 'vexport')).create();
  if (burnCues.isNotEmpty) {
    final font = File(p.join(work.path, 'NotoSans-Regular.ttf'));
    if (!await font.exists()) {
      final data = await rootBundle.load('assets/fonts/NotoSans-Regular.ttf');
      await font.writeAsBytes(data.buffer.asUint8List());
    }
    final srt = File(p.join(work.path, 'burn.srt'));
    await srt.writeAsString(toSrt(burnCues, from: from, to: to));
    srtPath = srt.path;
    fontsDir = work.path;
  }
  final outSeconds = (to - from) / speed;
  return runFfmpeg(
    buildExportArgs(
      input: input,
      output: output,
      from: from,
      to: to,
      speed: speed,
      srtPath: srtPath,
      fontsDir: fontsDir,
      hardwareEncoder: Platform.isIOS,
    ),
    onTime: (t) =>
        onProgress?.call(outSeconds <= 0 ? 0 : (t / outSeconds).clamp(0, 1)),
  );
}
