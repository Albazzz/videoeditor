import 'dart:async';

import 'audio_availability.dart';
import 'audio_feed.dart';
import 'retained_audio.dart';
import 'video_pipeline.dart';

/// Owns the single download slot until one video's entire audio is verified.
/// Recognition, seeks and recognizer preemption never own this writer.
class FullAudioDownload {
  FullAudioDownload({
    required this.videoId,
    required this.store,
    required this.archive,
    required this.duration,
    required this.source,
    required this.headers,
    required this.hls,
    required this.createFeed,
    required this.nextGeneration,
    required this.onProgress,
    required this.onStatus,
    this.onRetry,
    this.hidden = false,
    this.retryDelay = const Duration(seconds: 2),
  });

  final String videoId;
  final RetainedAudioStore store;
  final AudioArchive archive;
  final double Function() duration;
  final Future<String> Function() source;
  final Map<String, String> Function() headers;
  final bool Function() hls;
  final AudioFeed Function() createFeed;
  final int Function() nextGeneration;
  final void Function(AudioAvailability) onProgress;
  final void Function(String) onStatus;
  final void Function(String)? onRetry;
  final bool hidden;
  final Duration retryDelay;
  final _cancelled = Completer<void>();
  AudioFeed? _feed;
  Future<RetainedAudioLease?>? _task;
  bool get cancelled => _cancelled.isCompleted;
  bool get downloading => _feed != null && !_feed!.done;
  bool connecting = false;

  Future<RetainedAudioLease?> run() => _task ??= _run();

  void cancel() {
    if (cancelled) return;
    _cancelled.complete();
  }

  Future<void> close() async {
    cancel();
    try {
      await _task;
    } catch (_) {
      // The session reports failures; closing only waits for the writer.
    }
  }

  Future<AudioAvailability> _inspect() async {
    final available = await store.availability(
      videoId,
      duration: duration(),
      includeHidden: hidden,
    );
    onProgress(available);
    return available;
  }

  Future<void> _wait(Duration delay) =>
      Future.any([Future<void>.delayed(delay), _cancelled.future]);

  static (double, double?)? _nextGap(AudioAvailability audio) {
    if (audio.complete) return null;
    var at = 0.0;
    for (final range in audio.ranges) {
      if (audio.total > 0 && at >= audio.total - .001) return null;
      if (range.$1 > at + .001) {
        return (
          at,
          audio.total > 0 && audio.total < range.$1 ? audio.total : range.$1,
        );
      }
      if (range.$2 > at) at = range.$2;
    }
    return (at, audio.total > 0 ? audio.total : null);
  }

  Future<RetainedAudioLease?> _run() async {
    var audio = await _inspect();
    if (cancelled) return null;
    if (audio.complete) return store.acquire(videoId, includeHidden: hidden);
    onStatus('Đang chờ lượt tải trọn âm thanh của video');
    final release = await VideoPipeline.extraction.acquire(
      videoId,
      cancelled: _cancelled.future,
    );
    try {
      var failures = 0;
      while (!cancelled) {
        audio = await _inspect();
        if (audio.complete) {
          return store.acquire(videoId, includeHidden: hidden);
        }
        final gap = _nextGap(audio);
        if (gap == null) {
          throw StateError('Chưa xác nhận đủ âm thanh của video');
        }
        final before = audio.seconds;
        AudioFeed? feed;
        try {
          onStatus('Đang kết nối để tải đủ âm thanh');
          connecting = true;
          final input = await Future.any([
            source(),
            _cancelled.future.then<String>(
              (_) => throw StateError('Đã dừng tải âm thanh'),
            ),
          ]);
          connecting = false;
          if (cancelled) return null;
          final gen = nextGeneration();
          final directory = await archive.createRun(gen, gap.$1);
          if (cancelled) return null;
          feed = _feed = createFeed();
          onStatus('Đang tải trọn âm thanh · chưa bắt đầu nhận dạng và dịch');
          await feed.start(
            input: input,
            outDir: directory.path,
            headers: headers(),
            hls: hls(),
            startSec: gap.$1,
            lengthSec: gap.$2 == null ? null : gap.$2! - gap.$1,
          );
          var lastProgress = DateTime.now(), lastScan = DateTime(0);
          var seconds = before;
          while (!cancelled && !feed.done) {
            final now = DateTime.now();
            if (now.difference(lastScan) >= const Duration(seconds: 1)) {
              final current = await _inspect();
              lastScan = now;
              if (current.seconds > seconds + .01) {
                seconds = current.seconds;
                lastProgress = now;
              }
              if (now.difference(lastProgress) >= const Duration(seconds: 60)) {
                throw TimeoutException(
                  'Không tải thêm được âm thanh trong 60 giây',
                );
              }
            }
            await _wait(const Duration(milliseconds: 250));
          }
          if (cancelled) return null;
          if (feed.error?.isNotEmpty == true) throw StateError(feed.error!);
          // Only a successful extraction aimed at the true tail proves EOF.
          if (audio.endOfAudio == null &&
              (gap.$2 == null ||
                  duration() > 0 && gap.$2! >= duration() - .001)) {
            await archive.recordRunEnd(gen, gap.$1, videoDuration: duration());
          }
          final after = await _inspect();
          if (!after.complete && after.seconds <= before + .001) {
            throw StateError('Nguồn kết thúc nhưng chưa tải đủ âm thanh');
          }
          failures = 0;
        } catch (e) {
          if (cancelled) return null;
          onRetry?.call('$e');
          if (++failures >= 3) rethrow;
          onStatus('Tải âm thanh bị gián đoạn, đang nối lại (lần $failures/3)');
        } finally {
          // Do not give the next video a slot before this writer has stopped.
          await feed?.stop();
          _feed = null;
          connecting = false;
        }
        if (failures > 0) await _wait(retryDelay * failures);
      }
      return null;
    } finally {
      release();
    }
  }
}
