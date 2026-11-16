import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';
import 'app_log.dart';
import 'asr_worker.dart';
import 'audio_feed.dart';
import 'hls.dart';
import 'hls_proxy.dart';
import 'model_store.dart';
import 'subtitle_store.dart';
import 'translator.dart';

/// How far ahead of the viewer subtitles are made.
enum SubtitleMode {
  /// The whole film: on from where the viewer is to the end, then any
  /// stretch still missing.
  whole,

  /// Only a few minutes ahead of the viewer; rests until they catch up.
  follow,
}

/// In [SubtitleMode.follow], work rests once subtitles are this far ahead…
const kFollowAhead = 240.0;

/// …and starts again when the viewer is this close to where it stopped.
const kFollowResume = 90.0;

/// A seek further than this past the ready subtitles starts work at the
/// new place instead of catching up.
const kSeekJump = 30.0;

/// Where to work next, or null when nothing is missing that the mode
/// cares about. Missing stretches at or after the viewer come first.
double? nextStart({
  required List<(double, double)> covered,
  required double duration,
  required double position,
  required SubtitleMode mode,
}) {
  if (duration <= 0) return null;
  final gaps = <(double, double)>[];
  var from = 0.0;
  for (final r in mergeRanges(covered)) {
    if (r.$1 - from > 3) gaps.add((from, r.$1));
    if (r.$2 > from) from = r.$2;
  }
  if (duration - from > 3) gaps.add((from, duration));
  for (final g in gaps) {
    if (g.$2 > position + 1) return g.$1 > position ? g.$1 : position;
  }
  if (mode == SubtitleMode.whole && gaps.isNotEmpty) return gaps.first.$1;
  return null;
}

/// Where a run starting at [from] should stop: just inside the next
/// stretch that already has subtitles, or null to run to the end.
double? runEnd(List<(double, double)> covered, double from) {
  for (final r in mergeRanges(covered)) {
    if (r.$1 > from + 1) return r.$1 + 2;
  }
  return null;
}

final _noise = RegExp(r'[\s\p{P}\p{S}]', unicode: true);
const _fillerChars = '嗯呃啊哦唉哈欸诶呀あぁえぇおぉっー';
const _fillerWords = {'ah', 'uh', 'um', 'hmm', 'mm', 'oh', 'eh', 'ha', 'haha'};

/// A line that is only a sound ("嗯", "あっ", "Hmm…", a music note):
/// not worth showing or sending for translation.
bool isFiller(String text) {
  final core = text.replaceAll(_noise, '');
  if (core.isEmpty) return true;
  if (_fillerWords.contains(core.toLowerCase())) return true;
  return core.runes.every((r) => _fillerChars.contains(String.fromCharCode(r)));
}

/// What a session is doing, for the icon on the CC bar.
enum SessionActivity { working, stuck, paused, done, failed }

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
    this._mode = SubtitleMode.whole,
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

  /// Length of the video, once the player knows it.
  double duration = 0;

  /// The audio was followed to its real end, without errors. With an
  /// unknown [duration] this is the only proof the whole film was done.
  bool reachedEnd = false;
  double? _runEnd;

  /// Work is resting ([SubtitleMode.follow], far enough ahead).
  bool paused = false;
  double? _resumeAt;
  double _position = 0;
  int _autoRuns = 0;
  double? _lastAutoStart;
  int _fillers = 0;

  /// Last time audio was heard, a line came in or work restarted.
  DateTime lastActivity = DateTime.now();

  SessionActivity get activity {
    if (error != null) return SessionActivity.failed;
    if (finished) return SessionActivity.done;
    if (paused) return SessionActivity.paused;
    return DateTime.now().difference(lastActivity) > const Duration(seconds: 20)
        ? SessionActivity.stuck
        : SessionActivity.working;
  }

  /// Lines heard whose translation has not arrived yet.
  int waitingTranslation = 0;
  int _lateTranslations = 0;
  int _feedRetries = 0;
  double _seekTarget = -100;
  DateTime _lastSeekRestart = DateTime(0);
  DateTime _lastChunkAt = DateTime.now();

  SubtitleMode _mode;
  SubtitleMode get mode => _mode;
  set mode(SubtitleMode value) {
    if (value == _mode) return;
    _mode = value;
    AppLog.i('phụ đề', 'Chế độ: ${value.name}');
    if (_disposed) return;
    if (paused && value == SubtitleMode.whole) {
      unawaited(_restart(_resumeAt ?? processedUntil));
    } else if (finished && value == SubtitleMode.whole) {
      _carryOn();
    } else {
      _maybePause();
    }
    notifyListeners();
  }

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
    _position = at;
    AppLog.i(
      'phụ đề',
      'Bắt đầu: ${AppLog.url(input)} · tiếng $language · từ giây '
          '${at.toStringAsFixed(1)} · ${cues.length} dòng có sẵn · '
          'dịch: ${_translator.runtimeType}',
    );
    try {
      _set('Đang nạp mô hình nhận dạng…');
      _worker ??= await AsrWorker.spawn(await ModelStore.config(language));
      AppLog.i('phụ đề', 'Đã nạp bộ nhận dạng');
      if (_disposed) return;
      _sub ??= _worker!.events.listen(_onEvent);
      _prepareTranslator();
      final tmp = await getTemporaryDirectory();
      _root ??= await Directory(
        p.join(tmp.path, 'vsub'),
      ).create(recursive: true).then((d) => d.createTemp('s'));
      await _restart(at);
    } catch (e, st) {
      AppLog.e('phụ đề', 'Không khởi động được: $e', st);
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
          AppLog.i('dịch', 'Bộ dịch $language → vi sẵn sàng');
          _retranslate();
          notifyListeners();
        })
        .catchError((Object e) {
          AppLog.e('dịch', 'Không chuẩn bị được bộ dịch $language: $e');
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
          .timeout(_translator.timeout);
    } catch (e) {
      _translateFailures++;
      _lastTranslateError = '$e';
      // The first few say what is wrong; after that only now and then.
      if (_translateFailures <= 3 || _translateFailures % 25 == 0) {
        AppLog.e('dịch', 'Lần lỗi thứ $_translateFailures ($lang): $e');
      }
      return null;
    }
  }

  /// Translates lines that were shown in the original language.
  void _retranslate() {
    for (final c in List.of(cues)) {
      if (c.source.isEmpty || c.text != c.source) continue;
      // Started at once so a cloud translator can send them together.
      final pending = _translate(c.source, language);
      _translating = _translating.then((_) async {
        if (_disposed) return;
        final text = await pending;
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
  Future<String> _audioSource() async {
    final cached = _source;
    if (cached != null) return cached;
    if (!input.startsWith('http')) return _source = input;
    final resolved = await resolveAudioSource(
      input,
      headers,
      language: language == 'auto' ? '' : language,
    );
    _hls = '$resolved $input'.contains('m3u8');
    if (!_hls) return _source = resolved;
    // HLS goes through the relay, which strips fake picture headers.
    final proxy = _proxy ??= await HlsProxy.start(headers);
    AppLog.i('phụ đề', 'Lấy HLS qua bộ chuyển tiếp: ${AppLog.url(resolved)}');
    return _source = proxy.urlFor(resolved);
  }

  HlsProxy? _proxy;
  bool _hls = false;

  Future<void> _restart(double at) async {
    try {
      if (_feed != null && processedUntil > _base) {
        _covered.add((_base, processedUntil));
      }
      final gen = ++_gen;
      paused = false;
      _resumeAt = null;
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
      _lastChunkAt = DateTime.now();
      lastActivity = DateTime.now();
      finished = false;
      error = null;
      _feedError = '';
      _dir = await Directory(p.join(_root!.path, 'g$gen')).create();
      _worker!.reset(gen, _base);
      // Stop where subtitles already exist, so nothing is made twice.
      final end = _runEnd = runEnd(_covered, _base);
      AppLog.i(
        'phụ đề',
        'Làm từ giây ${_base.toStringAsFixed(1)}'
            '${end == null ? ' tới hết' : ' tới giây ${end.toStringAsFixed(1)}'}',
      );
      final feed = _feed = AudioFeed();
      final source = await _audioSource();
      await feed.start(
        input: source,
        outDir: _dir!.path,
        // The relay sends the page's headers itself.
        headers: _hls ? const {} : headers,
        hls: _hls,
        startSec: _base,
        lengthSec: end == null ? null : end - _base,
      );
      _set('Đang nghe và dịch…');
      _poll = Timer.periodic(const Duration(milliseconds: 400), (_) => _pump());
    } catch (e, st) {
      AppLog.e('phụ đề', 'Không lấy được âm thanh: $e', st);
      error = '$e';
      _set('Lỗi: $e');
    }
  }

  void _pump() {
    final feed = _feed;
    final dir = _dir;
    if (feed == null || dir == null || _lastSent) return;
    // No new audio for a minute while the worker sits idle: the stream
    // has stalled without ffmpeg noticing.
    if (!feed.done &&
        _pending == 0 &&
        DateTime.now().difference(_lastChunkAt) > const Duration(seconds: 60)) {
      _poll?.cancel();
      unawaited(feed.stop());
      _retryFeed('Không nhận thêm âm thanh trong 60 giây');
      return;
    }
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
      _lastChunkAt = DateTime.now();
      if (_lastSent) return;
    }
  }

  /// The audio ran out. That is only good news if some of it was heard.
  void _finish() {
    final heardNothing = processedUntil - _base < 1 && cues.isEmpty;
    AppLog.i(
      'phụ đề',
      'Hết âm thanh: nghe tới giây ${processedUntil.toStringAsFixed(1)}, '
          '$_chunksFed đoạn, $_linesHeard câu, ${cues.length} dòng',
    );
    if (_feedError.isNotEmpty) {
      final tail = _feedError.length > 1500
          ? _feedError.substring(_feedError.length - 1500)
          : _feedError;
      AppLog.e('ffmpeg', tail);
    }
    if (_feedError.isNotEmpty && !heardNothing && _feedRetries < 6) {
      // Part way through: links often carry a token that expires. Fetch
      // the playlist again and carry on from where it stopped.
      _retryFeed(_feedError);
      return;
    }
    if (_feedError.isNotEmpty && heardNothing) {
      error = _feedError;
      _set('Không tải được âm thanh của video này');
    } else if (_feedError.isEmpty && _carryOn()) {
      return;
    } else if (_feedError.isNotEmpty) {
      // Gave up part way: this is not the end of the film.
      error = _feedError;
      _set(
        'Mất kết nối tới video ở ${_clock(processedUntil)}, bấm CC lại để thử tiếp',
      );
    } else {
      // The audio really ran out (not a stop at existing subtitles).
      if (_runEnd == null) reachedEnd = true;
      finished = true;
      _set(
        cues.isEmpty
            ? 'Đã nghe hết nhưng không thấy lời thoại'
            : 'Đã xong phụ đề',
      );
    }
  }

  void _retryFeed(String why) {
    _feedRetries++;
    final at = processedUntil - 2 > _base ? processedUntil - 2 : _base;
    final short = why.length > 300 ? why.substring(why.length - 300) : why;
    AppLog.e(
      'phụ đề',
      'Âm thanh ngắt ở ${_clock(processedUntil)} (lần $_feedRetries): $short',
    );
    if (_feedRetries > 6) {
      error = why;
      _set('Mất kết nối tới video, bấm CC lại để thử tiếp');
      return;
    }
    _source = null;
    _set('Mất kết nối, đang nối lại (lần $_feedRetries)…');
    final gen = _gen;
    Future.delayed(Duration(seconds: 2 * _feedRetries), () {
      if (!_disposed && gen == _gen) unawaited(_restart(at));
    });
  }

  /// Plain-language summary of where the work is, for the CC bar.
  String get stage {
    final parts = <String>['Đã nghe tới ${_clock(processedUntil)}'];
    if (duration > 0) parts.last += ' / ${_clock(duration)}';
    if (waitingTranslation > 0) parts.add('chờ dịch $waitingTranslation câu');
    return parts.join(' · ');
  }

  /// Starts on the next missing stretch, or rests until the viewer gets
  /// near it. False when there is nothing left to do.
  bool _carryOn() {
    final next = nextStart(
      covered: covered,
      duration: duration,
      position: _position,
      mode: _mode,
    );
    if (next == null || _autoRuns >= 80) return false;
    // A run that got nowhere would otherwise be tried for ever.
    final last = _lastAutoStart;
    if (last != null && (next - last).abs() < 1) return false;
    _lastAutoStart = next;
    _autoRuns++;
    finished = false;
    if (_mode == SubtitleMode.follow && next - _position > kFollowAhead) {
      paused = true;
      _resumeAt = next;
      _set('Đã có phụ đề trước chỗ đang xem, tạm nghỉ');
      return true;
    }
    _set('Làm tiếp đoạn còn thiếu từ ${_clock(next)}');
    unawaited(_restart(next));
    return true;
  }

  static String _clock(double s) {
    final t = s.round();
    String two(int v) => v.toString().padLeft(2, '0');
    return t >= 3600
        ? '${t ~/ 3600}:${two(t ~/ 60 % 60)}:${two(t % 60)}'
        : '${t ~/ 60}:${two(t % 60)}';
  }

  /// In follow mode, stops fetching audio once far enough ahead.
  void _maybePause() {
    final feed = _feed;
    if (_mode != SubtitleMode.follow || paused || feed == null) return;
    if (feed.done || _lastSent) return;
    if (processedUntil - _position < kFollowAhead) return;
    paused = true;
    _resumeAt = null;
    _poll?.cancel();
    unawaited(feed.stop());
    AppLog.i('phụ đề', 'Tạm nghỉ ở giây ${processedUntil.toStringAsFixed(0)}');
    _set('Đã có phụ đề trước chỗ đang xem, tạm nghỉ');
  }

  void _onEvent(AsrEvent event) {
    if (_disposed || event.gen != _gen && event.gen != -1) return;
    switch (event) {
      case AsrSegment() when isFiller(event.text):
        _fillers++;
      case AsrSegment():
        final gen = _gen;
        _linesHeard++;
        // Translations start at once (a cloud translator sends lines heard
        // close together in one request); lines are added in order.
        final pending = _translatorReady
            ? _translate(event.text, _langOf(event))
            : Future<String?>.value();
        waitingTranslation++;
        _translating = _translating.then((_) async {
          if (_disposed || gen != _gen) {
            // A seek made this line stale: do not wait for it.
            waitingTranslation--;
            return;
          }
          // A slow translation must not hold up the lines after it: show
          // the original for now and swap the translation in later.
          final quick = await Future.any<Object?>([
            pending,
            Future<Object?>.delayed(const Duration(seconds: 8), () => _late),
          ]);
          if (identical(quick, _late)) {
            _lateTranslations++;
            unawaited(
              pending.then((text) {
                waitingTranslation--;
                if (text != null && !_disposed) {
                  _replaceText(event.start, event.text, text);
                }
                if (!_disposed) notifyListeners();
              }),
            );
          } else {
            waitingTranslation--;
          }
          final translated = quick is String ? quick : null;
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
        lastActivity = DateTime.now();
        _pending--;
        if (event.until > processedUntil + 30) _feedRetries = 0;
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
        AppLog.e('nhận dạng', event.message);
        error = event.message;
        _set('Lỗi nhận dạng: ${event.message}');
    }
  }

  static final _late = Object();

  /// Puts a translation that arrived late into the line already shown.
  void _replaceText(double start, String source, String text) {
    final i = cues.indexWhere(
      (x) => (x.start - start).abs() < 0.01 && x.source == source,
    );
    if (i < 0) return;
    cues[i] = Cue(
      start: cues[i].start,
      end: cues[i].end,
      text: text,
      source: source,
    );
    onCue?.call(cues[i]);
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
    lastActivity = DateTime.now();
    onCue?.call(cue);
    notifyListeners();
  }

  /// Tell the session where playback is; restarts the work after a far seek.
  void updatePosition(double t, {double duration = 0}) {
    if (duration > 0) this.duration = duration;
    _position = t;
    if (_worker == null || _feed == null || _disposed) return;
    final inOld = _covered.any((r) => t >= r.$1 - 1 && t <= r.$2 - 5);
    if (paused) {
      final resumeAt = _resumeAt ?? processedUntil;
      if (inOld || (t >= _base - 1 && t <= resumeAt + kSeekJump)) {
        _outOfRange = 0;
        if (resumeAt - t < kFollowResume) unawaited(_restart(resumeAt));
        return;
      }
    } else {
      // Close behind the work: it catches up faster than a restart.
      final inCurrent = t >= _base - 1 && t <= processedUntil + kSeekJump;
      if (inCurrent || inOld) {
        _outOfRange = 0;
        _maybePause();
        return;
      }
    }
    // A seek to a place without subtitles: work there, once the position
    // has settled (two reports close together) and not more often than
    // every 3 s, so dragging the slider does not restart ffmpeg each time.
    final settled = (t - _seekTarget).abs() < 2;
    _seekTarget = t;
    if (!settled) {
      _outOfRange = 0;
      return;
    }
    if (++_outOfRange < 2) return;
    final now = DateTime.now();
    if (now.difference(_lastSeekRestart) < const Duration(seconds: 3)) return;
    _outOfRange = 0;
    _lastSeekRestart = now;
    AppLog.i('phụ đề', 'Tua tới ${_clock(t)}, làm từ đó');
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
      'Bỏ qua tiếng đệm (嗯, あ…): $_fillers câu',
      'Đang chờ dịch: $waitingTranslation câu · dịch chậm (hiện câu gốc '
          'trước): $_lateTranslations câu',
      'Nối lại âm thanh: $_feedRetries lần',
      'Chế độ: ${_mode == SubtitleMode.whole ? 'làm hết phim' : 'chỉ làm trước chỗ đang xem'}'
          '${paused ? ' (đang nghỉ)' : ''}',
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
    AppLog.i('phụ đề', 'Dừng (${cues.length} dòng)');
    _disposed = true;
    _poll?.cancel();
    _sub?.cancel();
    _feed?.stop();
    _worker?.dispose();
    _translator.dispose();
    _proxy?.close();
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
