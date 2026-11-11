// Runs the real export command line through a desktop ffmpeg, when one is
// installed, to prove the trim + speed + burned subtitle filters are valid.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video/models/cue.dart';
import 'package:video/services/exporter.dart';

void main() {
  final hasFfmpeg = () {
    try {
      return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();

  test(
    'ffmpeg exports a trimmed 2.5x clip with Vietnamese subtitles',
    () async {
      final dir = await Directory.systemTemp.createTemp('vexport_test');
      addTearDown(() => dir.delete(recursive: true));
      final input = p.join(dir.path, 'in.mp4');
      final output = p.join(dir.path, 'out.mp4');
      final srt = File(p.join(dir.path, 'burn.srt'));

      final make = await Process.run('ffmpeg', [
        '-y',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'testsrc=duration=20:size=640x360:rate=30',
        '-f',
        'lavfi',
        '-i',
        'sine=frequency=440:duration=20',
        '-c:v',
        'libx264',
        '-pix_fmt',
        'yuv420p',
        '-c:a',
        'aac',
        input,
      ]);
      expect(make.exitCode, 0, reason: '${make.stderr}');

      const cues = [
        Cue(start: 6, end: 9, text: 'Xin chào, đây là phụ đề tiếng Việt'),
        Cue(start: 10, end: 14, text: 'Dòng thứ hai: ờ ở ỡ ợ ữ'),
      ];
      await srt.writeAsString(toSrt(cues, from: 5, to: 15));

      final run = await Process.run('ffmpeg', [
        '-loglevel',
        'error',
        ...buildExportArgs(
          input: input,
          output: output,
          from: 5,
          to: 15,
          speed: 2.5,
          srtPath: srt.path,
          fontsDir: p.join(Directory.current.path, 'assets', 'fonts'),
        ),
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');

      final probe = await Process.run('ffprobe', [
        '-v',
        'error',
        '-show_entries',
        'format=duration',
        '-of',
        'csv=p=0',
        output,
      ]);
      // 10 seconds of source at 2.5x is 4 seconds.
      expect(double.parse('${probe.stdout}'.trim()), closeTo(4.0, 0.3));
    },
    skip: hasFfmpeg ? false : 'ffmpeg is not installed',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
