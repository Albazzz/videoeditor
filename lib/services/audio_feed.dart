import 'dart:async';
import 'dart:io';

import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';

import 'app_log.dart';
import 'crash_trail.dart';

bool get _hasFfmpegKit => Platform.isIOS || Platform.isAndroid;

/// Seconds of audio per chunk file.
const int kChunkSeconds = 10;

/// Where the audio is cut, in seconds from where it starts. The first
/// chunks are short so the first line shows within a few seconds of
/// pressing CC; after that [kChunkSeconds] each, for up to [hours].
String segmentTimes({int hours = 8}) {
  final points = <int>[3, 8];
  for (var t = 8 + kChunkSeconds; t <= hours * 3600; t += kChunkSeconds) {
    points.add(t);
  }
  return points.join(',');
}

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

    /// Seconds of audio to take; null for everything to the end.
    double? lengthSec,

    /// The input is an HLS playlist (options below exist only for HLS).
    bool hls = false,
  }) async {
    if (_stopped) return;
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
      if (isUrl) ...[
        // Ride out short network drops instead of ending early, and give
        // up on a dead connection after 20 s instead of hanging for ever.
        '-reconnect', '1',
        '-reconnect_streamed', '1',
        '-reconnect_on_network_error', '1',
        '-reconnect_delay_max', '8',
        '-rw_timeout', '20000000',
      ],
      if (hls) ...[
        // Pieces hosted as pictures, without a video extension.
        '-allowed_segment_extensions', 'ALL',
        '-extension_picky', '0',
      ],
      if (startSec > 0) ...['-ss', startSec.toStringAsFixed(3)],
      '-i',
      input,
      if (lengthSec != null) ...['-t', lengthSec.toStringAsFixed(3)],
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
      '-segment_times',
      segmentTimes(),
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
          AppLog.i('ffmpeg', 'Lấy âm thanh kết thúc, mã $rc');
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
      if (_stopped) await FFmpegKit.cancel(_sessionId!);
    } else {
      // Desktop (development only): use the ffmpeg on PATH.
      final p = await Process.start('ffmpeg', ['-nostdin', ...args]);
      _process = p;
      if (_stopped) p.kill();
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
          AppLog.e(
            'xuất video',
            logs.length > 1500 ? logs.substring(logs.length - 1500) : logs,
          );
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
