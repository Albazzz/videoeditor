import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';
import 'asr_worker.dart';
import 'audio_feed.dart';
import 'hls.dart';
import 'model_store.dart';
import 'translator.dart';

/// Generates Vietnamese subtitles for one video while it plays.
///
/// Audio is decoded ahead of the playback position, recognised, translated
/// and appended to [cues]. Seeking outside what is already covered restarts
/// the work from the new position.
class SubtitleSession extends ChangeNotifier {
  SubtitleSession({
    required this.input,
    required this.language,
    this.headers = const {},
    Translator? translator,
    this.onCue,
  }) : _translator = translator ?? Translator.create();

  /// Local file path or http(s) URL (mp4, m3u8, ...).
  final String input;
  final String language;
  final Map<String, String> headers;
  final Translator _translator;

  /// Called for every new subtitle line.
  final void Function(Cue cue)? onCue;

  /// Sorted by start time.
  final List<Cue> cues = [];
  String status = 'Đang chuẩn bị…';
  String? error;

  /// True once the audio has been processed to the end of the video.
  bool finished = false;

  /// Speech is recognised up to this second in the current run.
  double processedUntil = 0;

  AsrWorker? _worker;
  StreamSubscription<AsrEvent>? _sub;
  AudioFeed? _feed;
  Timer? _poll;
  Directory? _root;
  Directory? _dir;
  int _gen = 0;
  double _base = 0;
  int _nextChunk = 0;
  int _pending = 0;
  bool _lastSent = false;
  int _outOfRange = 0;
  bool _disposed = false;
  String? _source;
  Future<void> _translating = Future.value();

  /// Ranges [from, to] already transcribed by earlier runs.
  final List<(double, double)> _covered = [];

  Future<void> start(double at) async {
    try {
      _set('Đang nạp mô hình nhận dạng…');
      _worker ??= await AsrWorker.spawn(await ModelStore.config(language));
      if (_disposed) return;
      _sub ??= _worker!.events.listen(_onEvent);
      if (language != 'auto') {
        _set('Đang chuẩn bị bộ dịch…');
        try {
          await _translator.prepare(language);
        } catch (e) {
          debugPrint('translator prepare failed: $e');
        }
      }
      if (_disposed) return;
      final tmp = await getTemporaryDirectory();
      _root ??= await Directory(
        p.join(tmp.path, 'vsub'),
      ).create(recursive: true).then((d) => d.createTemp('s'));
      await _restart(at);
    } catch (e) {
      error = '$e';
      _set('Lỗi: $e');
    }
  }

  /// Where ffmpeg reads audio from; resolved once per session.
  Future<String> _audioSource() async => _source ??= input.startsWith('http')
      ? await resolveAudioSource(
          input,
          headers,
          language: language == 'auto' ? '' : language,
        )
      : input;

  Future<void> _restart(double at) async {
    if (_feed != null && processedUntil > _base) {
      _covered.add((_base, processedUntil));
    }
    final gen = ++_gen;
    _poll?.cancel();
    await _feed?.stop();
    final old = _dir;
    if (old != null) {
      unawaited(old.delete(recursive: true).catchError((_) => old));
    }
    if (_disposed || gen != _gen) return;

    _base = at < 0 ? 0 : at;
    processedUntil = _base;
    _nextChunk = 0;
    _pending = 0;
    _lastSent = false;
    finished = false;
    error = null;
    _dir = await Directory(p.join(_root!.path, 'g$gen')).create();
    _worker!.reset(gen, _base);
    final feed = _feed = AudioFeed();
    await feed.start(
      input: await _audioSource(),
      outDir: _dir!.path,
      headers: headers,
      startSec: _base,
    );
    _set('Đang nghe và dịch…');
    _poll = Timer.periodic(const Duration(milliseconds: 400), (_) => _pump());
  }

  void _pump() {
    final feed = _feed;
    final dir = _dir;
    if (feed == null || dir == null || _lastSent) return;
    // Keep the worker's queue short so a seek takes effect quickly.
    while (_pending < 3) {
      final current = File(p.join(dir.path, chunkName(_nextChunk)));
      final next = File(p.join(dir.path, chunkName(_nextChunk + 1)));
      final hasNext = next.existsSync();
      if (hasNext) {
        _worker!.feed(_gen, current.path);
      } else if (feed.done) {
        if (current.existsSync()) {
          _worker!.feed(_gen, current.path, last: true);
          _lastSent = true;
        } else {
          _lastSent = true;
          if (feed.error != null && _nextChunk == 0) {
            error = feed.error;
            _set('Không đọc được âm thanh của video này');
          } else if (_pending == 0) {
            finished = true;
            _set('Đã xong phụ đề');
          }
          return;
        }
      } else {
        return;
      }
      _pending++;
      _nextChunk++;
      if (_lastSent) return;
    }
  }

  void _onEvent(AsrEvent event) {
    if (_disposed || event.gen != _gen && event.gen != -1) return;
    switch (event) {
      case AsrSegment():
        final gen = _gen;
        // Translate one at a time so lines stay in order.
        _translating = _translating.then((_) async {
          var text = event.text;
          try {
            text = await _translator.translate(event.text, _langOf(event));
          } catch (e) {
            debugPrint('translate failed: $e');
          }
          if (_disposed || gen != _gen) return;
          _addCue(
            Cue(
              start: event.start,
              end: event.end + 0.4,
              text: text,
              source: event.text,
            ),
          );
        });
      case AsrProgress():
        _pending--;
        processedUntil = event.until;
        if (event.last || (_lastSent && _pending <= 0)) {
          finished = true;
          _set('Đã xong phụ đề');
        } else {
          notifyListeners();
        }
      case AsrError():
        error = event.message;
        _set('Lỗi nhận dạng: ${event.message}');
    }
  }

  String _langOf(AsrSegment s) =>
      language == 'auto' ? (s.lang.isEmpty ? 'ja' : s.lang) : language;

  void _addCue(Cue cue) {
    // After seeking back, the same speech can be recognised twice.
    for (final c in cues) {
      final overlap =
          (cue.end < c.end ? cue.end : c.end) -
          (cue.start > c.start ? cue.start : c.start);
      if (overlap > 0.5 * (cue.end - cue.start)) return;
    }
    var i = cues.length;
    while (i > 0 && cues[i - 1].start > cue.start) {
      i--;
    }
    // Never let a line linger over the next one.
    if (i > 0 && cues[i - 1].end > cue.start) {
      final prev = cues[i - 1];
      cues[i - 1] = Cue(
        start: prev.start,
        end: cue.start,
        text: prev.text,
        source: prev.source,
      );
    }
    cues.insert(i, cue);
    onCue?.call(cue);
    notifyListeners();
  }

  /// Tell the session where playback is; restarts the work after a far seek.
  void updatePosition(double t) {
    if (_worker == null || _feed == null || _disposed) return;
    final inCurrent = t >= _base - 1 && t <= processedUntil + 120;
    final inOld = _covered.any((r) => t >= r.$1 - 1 && t <= r.$2 - 5);
    if (inCurrent || inOld) {
      _outOfRange = 0;
      return;
    }
    // Wait for the position to settle so scrubbing does not thrash.
    if (++_outOfRange < 3) return;
    _outOfRange = 0;
    unawaited(_restart(t));
  }

  Cue? at(double t) => cueAt(cues, t);

  /// How far ahead of [t] subtitles are ready (seconds, may be negative).
  double leadOver(double t) => processedUntil - t;

  void _set(String s) {
    status = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _poll?.cancel();
    _sub?.cancel();
    _feed?.stop();
    _worker?.dispose();
    _translator.dispose();
    final root = _root;
    if (root != null) {
      // Give ffmpeg a moment to let go of its output file.
      Future.delayed(
        const Duration(seconds: 1),
        () => root.delete(recursive: true).catchError((_) => root),
      );
    }
    super.dispose();
  }
}
