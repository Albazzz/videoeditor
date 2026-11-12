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
    List<Cue> initialCues = const [],
    List<(double, double)> initialCovered = const [],
  }) : _translator = translator ?? Translator.create() {
    cues.addAll(initialCues);
    _covered.addAll(initialCovered);
  }

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

  /// What the translator is doing, empty when it is simply working.
  String translatorNote = '';

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
  bool _translatorReady = false;

  // Counters for the "what is going on" panel.
  int _chunksFed = 0;
  int _linesHeard = 0;
  int _translateFailures = 0;
  String _lastTranslateError = '';
  String _feedError = '';
  final DateTime _created = DateTime.now();

  /// Ranges [from, to] already transcribed by earlier runs.
  final List<(double, double)> _covered = [];

  /// Every range transcribed so far, including the one in progress.
  List<(double, double)> get covered => [
    ..._covered,
    if (processedUntil > _base) (_base, processedUntil),
  ];

  /// Removes audio left behind when the app was killed mid-session. Call
  /// once at launch, before any session exists.
  static Future<void> cleanLeftovers() async {
    try {
      final tmp = await getTemporaryDirectory();
      final dir = Directory(p.join(tmp.path, 'vsub'));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  }

  Future<void> start(double at) async {
    try {
      _set('Đang nạp mô hình nhận dạng…');
      _worker ??= await AsrWorker.spawn(await ModelStore.config(language));
      if (_disposed) return;
      _sub ??= _worker!.events.listen(_onEvent);
      _prepareTranslator();
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

  /// The translator may need a download. Recognition must not wait for it:
  /// lines appear in the original language first and are translated once it
  /// is ready.
  void _prepareTranslator() {
    if (language == 'auto') {
      _translatorReady = true;
      return;
    }
    translatorNote = 'Đang tải bộ dịch, tạm hiện câu gốc';
    _translator
        .prepare(language)
        .timeout(const Duration(minutes: 5))
        .then((_) {
          if (_disposed) return;
          _translatorReady = true;
          translatorNote = '';
          _retranslate();
          notifyListeners();
        })
        .catchError((Object e) {
          if (_disposed) return;
          translatorNote = 'Bộ dịch chưa dùng được, đang hiện câu gốc';
          _lastTranslateError = '$e';
          notifyListeners();
        });
  }

  Future<String?> _translate(String text, String lang) async {
    try {
      return await _translator
          .translate(text, lang)
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      _translateFailures++;
      _lastTranslateError = '$e';
      return null;
    }
  }

  /// Translates lines that were shown in the original language.
  void _retranslate() {
    for (final c in List.of(cues)) {
      if (c.source.isEmpty || c.text != c.source) continue;
      _translating = _translating.then((_) async {
        if (_disposed) return;
        final text = await _translate(c.source, language);
        if (text == null || _disposed) return;
        final i = cues.indexWhere(
          (x) => x.start == c.start && x.source == c.source,
        );
        if (i < 0) return;
        cues[i] = Cue(
          start: cues[i].start,
          end: cues[i].end,
          text: text,
          source: c.source,
        );
        onCue?.call(cues[i]);
        notifyListeners();
      });
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
    try {
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

      // Do not redo a stretch that already has subtitles.
      var from = at < 0 ? 0.0 : at;
      for (final r in _covered) {
        if (from >= r.$1 - 1 && from < r.$2 - 5) from = r.$2 - 2;
      }
      _base = from;
      processedUntil = _base;
      _nextChunk = 0;
      _pending = 0;
      _lastSent = false;
      finished = false;
      error = null;
      _feedError = '';
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
    } catch (e) {
      error = '$e';
      _set('Lỗi: $e');
    }
  }

  void _pump() {
    final feed = _feed;
    final dir = _dir;
    if (feed == null || dir == null || _lastSent) return;
    // Keep the worker's queue short so a seek takes effect quickly.
    while (_pending < 3) {
      final current = File(p.join(dir.path, chunkName(_nextChunk)));
      final next = File(p.join(dir.path, chunkName(_nextChunk + 1)));
      if (next.existsSync()) {
        _worker!.feed(_gen, current.path);
      } else if (feed.done) {
        _feedError = feed.error ?? '';
        _lastSent = true;
        if (current.existsSync()) {
          _worker!.feed(_gen, current.path, last: true);
        } else {
          if (_pending == 0) _finish();
          return;
        }
      } else {
        return;
      }
      _pending++;
      _nextChunk++;
      _chunksFed++;
      if (_lastSent) return;
    }
  }

  /// The audio ran out. That is only good news if some of it was heard.
  void _finish() {
    final heardNothing = processedUntil - _base < 1 && cues.isEmpty;
    if (_feedError.isNotEmpty && heardNothing) {
      error = _feedError;
      _set('Không tải được âm thanh của video này');
    } else {
      finished = true;
      _set(
        cues.isEmpty
            ? 'Đã nghe hết nhưng không thấy lời thoại'
            : 'Đã xong phụ đề',
      );
    }
  }

  void _onEvent(AsrEvent event) {
    if (_disposed || event.gen != _gen && event.gen != -1) return;
    switch (event) {
      case AsrSegment():
        final gen = _gen;
        _linesHeard++;
        // Translate one at a time so lines stay in order.
        _translating = _translating.then((_) async {
          final translated = _translatorReady
              ? await _translate(event.text, _langOf(event))
              : null;
          if (_disposed || gen != _gen) return;
          _addCue(
            Cue(
              start: event.start,
              end: event.end + 0.4,
              text: translated ?? event.text,
              source: event.text,
            ),
          );
        });
      case AsrProgress():
        _pending--;
        processedUntil = event.until;
        if (event.last || (_lastSent && _pending <= 0)) {
          // Let queued translations land before judging the result.
          _translating.then((_) {
            if (!_disposed && event.gen == _gen) _finish();
          });
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

  /// Plain-text account of every stage, for working out why nothing shows.
  String get details {
    String clip(String s, [int n = 300]) =>
        s.length > n ? '${s.substring(0, n)}…' : s;
    final seconds = DateTime.now().difference(_created).inSeconds;
    return [
      'Trạng thái: $status',
      'Chạy được: $seconds giây',
      'Ngôn ngữ: $language',
      'Nguồn video: ${clip(input, 160)}',
      'Nguồn âm thanh: ${clip(_source ?? '(chưa xác định)', 160)}',
      'Mô hình nhận dạng: ${_worker == null ? 'chưa nạp' : 'đã nạp'}',
      'Bắt đầu từ giây: ${_base.toStringAsFixed(1)}',
      'Đã nghe tới giây: ${processedUntil.toStringAsFixed(1)}',
      'Số đoạn âm thanh đã nhận: $_chunksFed',
      'Số câu nghe được: $_linesHeard',
      'Số dòng phụ đề: ${cues.length}',
      'Bộ dịch: ${_translatorReady ? 'sẵn sàng' : 'chưa sẵn sàng'}'
          '${translatorNote.isEmpty ? '' : ' ($translatorNote)'}',
      'Dịch lỗi: $_translateFailures lần'
          '${_lastTranslateError.isEmpty ? '' : ' · ${clip(_lastTranslateError)}'}',
      if (_feedError.isNotEmpty) 'Lỗi tải âm thanh: ${clip(_feedError, 600)}',
      if (error != null) 'Lỗi: ${clip(error!, 600)}',
    ].join('\n');
  }

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
