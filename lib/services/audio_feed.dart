import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import 'crash_trail.dart';

bool get _hasFfmpegKit => Platform.isIOS || Platform.isAndroid;

/// Seconds of audio per chunk file.
const int kChunkSeconds = 10;

String chunkName(int index) => 'c_${index.toString().padLeft(5, '0')}.wav';

/// Decodes the audio of a video file or stream URL into small 16 kHz mono
/// WAV chunks, as fast as the source allows.
class AudioFeed {
  bool done = false;
  String? error;

  int? _sessionId;
  Process? _process;
  bool _stopped = false;

  Future<void> start({
    required String input,
    required String outDir,
    Map<String, String> headers = const {},
    double startSec = 0,
  }) async {
    final isUrl = input.startsWith('http');
    final other = headers.entries
        .where((e) => e.key != 'User-Agent')
        .map((e) => '${e.key}: ${e.value}\r\n')
        .join();
    final args = <String>[
      '-y',
      '-loglevel',
      'error',
      // ffmpeg sends its own User-Agent unless told otherwise, so it must
      // not also appear in the extra headers.
      if (isUrl && headers['User-Agent'] != null) ...[
        '-user_agent',
        headers['User-Agent']!,
      ],
      if (isUrl && other.isNotEmpty) ...['-headers', other],
      if (startSec > 0) ...['-ss', startSec.toStringAsFixed(3)],
      '-i',
      input,
      '-vn',
      '-sn',
      '-dn',
      '-map',
      '0:a:0',
      '-ac',
      '1',
      '-ar',
      '16000',
      '-c:a',
      'pcm_s16le',
      '-f',
      'segment',
      '-segment_time',
      '$kChunkSeconds',
      '-segment_format',
      'wav',
      '-reset_timestamps',
      '1',
      '$outDir${Platform.pathSeparator}c_%05d.wav',
    ];

    if (_hasFfmpegKit) {
      final session = await CrashTrail.guard(
        'Khởi động ffmpeg để lấy âm thanh',
        () => FFmpegKit.executeWithArgumentsAsync(args, (s) async {
          if (_stopped) return;
          final rc = await s.getReturnCode();
          if (!ReturnCode.isSuccess(rc)) {
            final logs = await s.getAllLogsAsString();
            error = (logs ?? '').trim().isEmpty
                ? 'ffmpeg lỗi $rc'
                : logs!.trim();
          }
          done = true;
        }),
      );
      _sessionId = session.getSessionId();
    } else {
      // Desktop (development only): use the ffmpeg on PATH.
      final p = await Process.start('ffmpeg', ['-nostdin', ...args]);
      _process = p;
      final err = StringBuffer();
      p.stdout.drain<void>();
      p.stderr.transform(const SystemEncoding().decoder).listen(err.write);
      unawaited(
        p.exitCode.then((code) {
          if (_stopped) return;
          if (code != 0) error = err.toString().trim();
          done = true;
        }),
      );
    }
  }

  Future<void> stop() async {
    _stopped = true;
    done = true;
    final id = _sessionId;
    if (id != null) await FFmpegKit.cancel(id);
    _process?.kill();
  }
}

/// Result of a one-shot ffmpeg run (used for exporting edited videos).
Future<String?> runFfmpeg(
  List<String> args, {
  void Function(double seconds)? onTime,
}) async {
  if (_hasFfmpegKit) {
    final completer = Completer<String?>();
    await FFmpegKit.executeWithArgumentsAsync(
      args,
      (s) async {
        final rc = await s.getReturnCode();
        if (ReturnCode.isSuccess(rc)) {
          completer.complete(null);
        } else {
          final logs = (await s.getAllLogsAsString() ?? '').trim();
          final tail = logs.length > 600
              ? logs.substring(logs.length - 600)
              : logs;
          completer.complete(tail.isEmpty ? 'ffmpeg lỗi $rc' : tail);
        }
      },
      null,
      (stats) => onTime?.call(stats.getTime() / 1000),
    );
    return completer.future;
  }
  final r = await Process.run('ffmpeg', ['-nostdin', ...args]);
  return r.exitCode == 0 ? null : '${r.stderr}'.trim();
}
