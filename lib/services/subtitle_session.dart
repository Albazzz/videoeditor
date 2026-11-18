import 'dart:async';
import 'dart:io';

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';
import 'app_log.dart';
import 'app_settings.dart';
import 'asr_worker.dart';
import 'audio_feed.dart';
import 'hls.dart';
import 'hls_proxy.dart';
import 'model_store.dart';
import 'openrouter_translator.dart';
import 'subtitle_store.dart';
import 'translator.dart';
import 'video_language.dart';
import 'video_pipeline.dart';
import 'retained_audio.dart';

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

enum StageState { waiting, active, done, failed, skipped }

/// One stage of making subtitles, as shown in the progress sheet.
class SessionStep {
  const SessionStep(this.title, this.state, [this.detail = '']);
  final String title;
  final StageState state;
  final String detail;
}

/// What a session is doing, for the icon on the CC bar.
enum SessionActivity { working, stuck, paused, done, failed }

/// Disjoint reservations; the audio reader adds at most two seconds at a seam.
List<(double, double)> planRuns({
  required List<(double, double)> covered,
  required double duration,
  required double position,
  required int slots,
}) {
  if (duration <= 0 || slots <= 0) return [];
  final gaps = <(double, double)>[];
  var at = 0.0;
  for (final r in mergeRanges(covered)) {
    final end = math.min(duration, r.$1);
    if (end - at > 3) gaps.add((at, end));
    at = math.max(at, r.$2);
  }
  if (duration - at > 3) gaps.add((at, duration));
  if (gaps.isEmpty) return [];
  final viewer = position.clamp(0.0, duration);
  final first = gaps.firstWhere(
    (g) => g.$2 > viewer + 1,
    orElse: () => gaps.first,
  );
  final start = viewer > first.$1 && viewer < first.$2 - 1 ? viewer : first.$1;
  final runs = [(start, first.$2)];
  if (slots == 1) return runs;
  // A short gap costs more to split than to finish with one worker.
  if (gaps.length == 1 && first.$2 - first.$1 <= 2 * kSeekJump) return [first];
  for (final gap in gaps) {
    if (gap == first) {
      if (start - gap.$1 > 3) runs.add((gap.$1, start));
    } else {
      runs.add(gap);
    }
    if (runs.length == math.min(slots, 2)) return runs;
  }
  if (runs.length == 1 && first.$2 - start > 2 * kSeekJump) {
    final mid = (start + first.$2) / 2;
    return [(start, mid), (mid, first.$2)];
  }
  return runs;
}

class _Run {
  _Run(this.slot, this.gen, this.base, this.end) : processedUntil = base;
  final int slot, gen;
  final double base;
  final double? end;
  double processedUntil;
  AsrWorker? worker;
  Future<void>? opening;
  StreamSubscription<AsrEvent>? sub;
  AudioFeed? feed;
  Directory? dir;
  Directory? audioDir;
  Timer? poll;
  DateTime lastChunk = DateTime.now();
  int pending = 0, nextChunk = 0;
  bool lastSent = false;
  void Function()? releaseRecognition;
  void Function()? releaseModel;
  void Function()? releaseExtraction;
  Timer? extractionPoll;
  final cancelled = Completer<void>();
}

/// Recognises disjoint stretches of one film, with one shared subtitle list
/// and translation queue for both workers.
class SubtitleSession extends ChangeNotifier with WidgetsBindingObserver {
  SubtitleSession({
    required this.input,
    required String language,
    String? videoId,
    this.headers = const {},
    Translator? translator,
    this.onCue,
    SavedSubs? saved,
    List<Cue> initialCues = const [],
    List<(double, double)> initialCovered = const [],
    this._mode = SubtitleMode.whole,
    bool? parallel,
    Future<AsrWorker> Function(String)? createWorker,
    AudioFeed Function()? createFeed,
    Future<Directory> Function()? temporaryDirectory,
    RetainedAudioStore? retainedAudio,
  }) : videoId = videoId ?? input,
       _language = VideoLanguage(
         saved?.language.isNotEmpty == true ? saved!.language : language,
       ),
       _parallel = parallel ?? appSettings.parallelSubtitles,
       _translator = translator ?? Translator.create(videoId: videoId ?? input),
       _createWorker = createWorker ?? _spawn,
       _createFeed = createFeed ?? AudioFeed.new,
       audioStore = retainedAudio ?? RetainedAudioStore.instance,
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory {
    if (saved != null &&
        saved.source.isNotEmpty &&
        (saved.source != input || saved.id != this.videoId)) {
      throw ArgumentError('Phụ đề đã lưu thuộc video khác');
    }
    cues.addAll(saved?.cues ?? initialCues);
    _covered.addAll(saved?.covered ?? initialCovered);
  }

  static Future<AsrWorker> _spawn(String lang) async =>
      AsrWorker.spawn(await ModelStore.config(lang));

  final String input, videoId;
  final RetainedAudioStore audioStore;
  String audioTitle = '';
  bool audioHidden = false;
  AudioArchive? _audioArchive;
  Future<AudioArchive>? _audioOpening;
  Future<void>? _audioClosing;
  bool _audioCompleted = false;

  Future<void> markAudioCompleted() async {
    if (_audioCompleted || _audioArchive == null) return;
    _audioCompleted = true;
    await _audioArchive!.update(completed: true);
  }

  Future<void> closeAudio() => _audioClosing ??= () async {
    await Future.wait(_retiring.toList());
    final opening = _audioOpening;
    if (opening == null) return;
    AudioArchive archive;
    try {
      archive = await opening;
    } catch (_) {
      return;
    }
    await archive.close();
  }();
  final VideoLanguage _language;
  String get language => _language.code;
  bool get languageLocked => _language.locked;
  String get languageNotice => languageLocked
      ? '${kLanguages[language] ?? language} — dùng cho toàn bộ video'
      : 'Đang nhận diện ngôn ngữ từ lời thoại…';
  int _translationEpoch = 0;
  final Map<String, String> headers;
  final void Function(Cue cue)? onCue;
  final Future<AsrWorker> Function(String) _createWorker;
  final AudioFeed Function() _createFeed;
  final Future<Directory> Function() _temporaryDirectory;
  final List<Cue> cues = [];
  final _covered = <(double, double)>[];
  final _runs = <int, _Run>{};
  final _retiring = <Future<void>>{};
  final _retryCount = <int, int>{};
  final _translations = <String, Future<String?>>{};
  final _blockedTranslations = <String>{};
  final _pendingCues = <(double, String)>{};
  final _cueLanguages = <(double, String), String>{};

  Translator _translator;
  SubtitleMode _mode;
  bool _parallel, _lowMemory = false, _started = false, _disposed = false;
  bool _translatorReady = false, _changingEngine = false;
  bool finished = false, reachedEnd = false, paused = false;
  bool stopped = false;
  double duration = 0, _position = 0, _seekTarget = -100, _lastProcessed = 0;
  int _outOfRange = 0, _nextGen = 0, _epoch = 0;
  int _chunksFed = 0, _linesHeard = 0, _fillers = 0, _translateFailures = 0;
  int cueRevision = 0;
  String status = 'Đang chuẩn bị…',
      translatorNote = '',
      _lastTranslateError = '';
  String? error;
  String? _prepareError;
  DateTime lastActivity = DateTime.now(), _lastSeekRestart = DateTime(0);
  Directory? _root;
  Timer? _tick;
  Future<String>? _resolving;
  String? _source;
  String _feedError = '';
  double? _resumeAt;
  double? _audioEnd;
  double get _planDuration => _audioEnd ?? duration;

  int get waitingTranslation => _pendingCues.length;
  double get processedUntil =>
      _runs[0]?.processedUntil ??
      _runs.values.firstOrNull?.processedUntil ??
      _lastProcessed;
  List<(double, double)> get covered => mergeRanges([
    ..._covered,
    for (final r in _runs.values)
      if (r.processedUntil > r.base) (r.base, r.processedUntil),
  ]);
  int get _slots =>
      _mode == SubtitleMode.whole && _parallel && !_lowMemory ? 2 : 1;
  bool _owns(_Run r) => !_disposed && !stopped && identical(_runs[r.slot], r);

  SessionActivity get activity {
    if (error != null) return SessionActivity.failed;
    if (finished &&
        waitingTranslation == 0 &&
        (_translatorReady ||
            _prepareError != null ||
            _translator.status.state == TranslationState.disabled)) {
      return SessionActivity.done;
    }
    if (paused) return SessionActivity.paused;
    if (waitingTranslation > 0 ||
        _translator.status.state == TranslationState.downloading) {
      return SessionActivity.working;
    }
    return DateTime.now().difference(lastActivity) > const Duration(seconds: 20)
        ? SessionActivity.stuck
        : SessionActivity.working;
  }

  SubtitleMode get mode => _mode;
  set mode(SubtitleMode value) {
    if (_mode == value) return;
    _mode = value;
    if (_root != null) unawaited(_replan());
  }

  set parallel(bool value) {
    if (_parallel == value) return;
    _parallel = value;
    if (_root != null && _mode == SubtitleMode.whole && !_lowMemory) {
      unawaited(_replan());
    }
  }

  @override
  void didHaveMemoryPressure() {
    if (_lowMemory || _disposed) return;
    _lowMemory = true;
    final second = _runs[1];
    if (second != null) {
      AppLog.i('phụ đề', 'Thiếu bộ nhớ, dừng lượt 2 và làm tiếp bằng một lượt');
      _retire(second);
      _schedule();
      notifyListeners();
    }
  }

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
    if (_disposed || _started) return;
    _started = true;
    _position = math.max(0, at);
    WidgetsBinding.instance.addObserver(this);
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!finished || waitingTranslation > 0) notifyListeners();
    });
    AppLog.i(
      'phụ đề',
      'Bắt đầu ${AppLog.url(input)} · tiếng $language · ${cues.length} dòng có sẵn',
    );
    _prepareTranslator();
    try {
      final tmp = await _temporaryDirectory();
      final parent = await Directory(
        p.join(tmp.path, 'vsub'),
      ).create(recursive: true);
      final root = await parent.createTemp('s');
      if (_disposed) {
        await root.delete(recursive: true);
        return;
      }
      _root = root;
      _audioOpening = audioStore.create(
        videoId,
        title: audioTitle,
        hidden: audioHidden,
      );
      _audioArchive = await _audioOpening;
      if (_disposed || stopped) {
        await closeAudio();
        return;
      }
      _schedule();
    } catch (e, st) {
      _fail('$e', st);
    }
  }

  void _prepareTranslator() {
    final engine = _translator;
    final epoch = _translationEpoch;
    Future<void> prepare() async {
      try {
        if (language != 'auto') {
          await engine.prepare(language).timeout(const Duration(minutes: 5));
        }
        if (_disposed || engine != _translator || epoch != _translationEpoch) {
          return;
        }
        _translatorReady = true;
        _retranslate();
      } catch (e) {
        if (_disposed || engine != _translator || epoch != _translationEpoch) {
          return;
        }
        _prepareError = _lastTranslateError = 'Không chuẩn bị được bộ dịch: $e';
        AppLog.e('dịch', _lastTranslateError);
      }
      notifyListeners();
    }

    unawaited(prepare());
  }

  void _retranslate() {
    if (stopped ||
        !languageLocked ||
        !_translatorReady ||
        _translator.status.state == TranslationState.disabled) {
      return;
    }
    final remaining = [
      for (final c in cues)
        if (c.source.isNotEmpty && c.source == c.text) c,
    ];
    bool near(Cue c) => c.end >= _position && c.start < _position + 20;
    for (final c in [
      ...remaining.where(near),
      ...remaining.where((c) => !near(c)),
    ]) {
      _queueCue(c, language);
    }
  }

  void _queueCue(Cue cue, String lang) {
    final key = '$lang|${cue.source}';
    final id = (cue.start, cue.source);
    if (stopped ||
        !languageLocked ||
        !_translatorReady ||
        _translator.status.state == TranslationState.disabled ||
        _blockedTranslations.contains(key) ||
        !_pendingCues.add(id)) {
      return;
    }
    final engine = _translator;
    final translationEpoch = _translationEpoch;
    final future = _translations.putIfAbsent(
      key,
      () => _doTranslate(engine, cue, lang).whenComplete(() {
        if (translationEpoch == _translationEpoch) _translations.remove(key);
      }),
    );
    unawaited(
      future.then((text) {
        if (_disposed || stopped || translationEpoch != _translationEpoch) {
          return;
        }
        _pendingCues.remove(id);
        if (text != null && text != cue.source) {
          _replaceText(cue.start, cue.source, text);
        }
        if (engine != _translator && _translatorReady) _queueCue(cue, lang);
        lastActivity = DateTime.now();
        notifyListeners();
      }),
    );
  }

  Future<String?> _doTranslate(Translator engine, Cue c, String lang) async {
    try {
      if (engine is OpenRouterTranslator) {
        engine.position = _position;
        return await engine.translate(c.source, lang, start: c.start);
      }
      if (engine is MlKitTranslator) {
        engine.position = _position;
        return await engine.translate(c.source, lang, start: c.start);
      }
      return await engine.translate(c.source, lang).timeout(engine.timeout);
    } catch (e) {
      if (_disposed || e is TranslationCancelled || engine != _translator) {
        return null;
      }
      if (e is OpenRouterError && (e.blocked || e.permanent)) {
        _blockedTranslations.add('$lang|${c.source}');
      }
      _translateFailures++;
      _lastTranslateError = '$e';
      if (_translateFailures <= 3 || _translateFailures % 25 == 0) {
        AppLog.e('dịch', _lastTranslateError);
      }
      if (e is OpenRouterError && e.account && !_changingEngine) {
        _changingEngine = true;
        translatorNote = '${e.message} · tạm dùng bộ dịch trên máy';
        AppLog.e('dịch', translatorNote);
        _translator = TranslatorPacks.supported
            ? MlKitTranslator()
            : PassthroughTranslator();
        _translatorReady = false;
        unawaited(engine.dispose());
        _prepareTranslator();
      }
      return null;
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
    if (_disposed) throw const TranslationCancelled();
    _hls = '$resolved $input'.contains('m3u8');
    if (_noRelay) return _source = resolved;
    // A plain file is read by ffmpeg directly (one fast stream); the relay
    // (small ranged reads through iOS networking) only once the server has
    // turned ffmpeg away.
    if (!_hls && !_fileRelay) return _source = resolved;
    // HLS goes through the relay, which strips fake picture headers.
    final proxy = _proxy ??= await HlsProxy.start(headers);
    if (_disposed) {
      await proxy.close();
      throw const TranslationCancelled();
    }
    if (!_hls) return _source = proxy.urlForFile(resolved);
    AppLog.i('phụ đề', 'Lấy HLS qua bộ chuyển tiếp: ${AppLog.url(resolved)}');
    return _source = proxy.urlFor(resolved);
  }

  HlsProxy? _proxy;
  bool _hls = false;

  /// The relay could not fetch this stream; ffmpeg fetches it itself.
  bool _noRelay = false;

  /// A plain file is fetched through the relay (ffmpeg was turned away).
  bool _fileRelay = false;

  void _schedule() {
    if (_disposed || stopped || _root == null || error != null || paused) {
      return;
    }
    final occupied = [
      ...covered,
      for (final r in _runs.values) (r.base, r.end ?? double.infinity),
    ];
    final free = [
      for (var i = 0; i < _slots; i++)
        if (!_runs.containsKey(i)) i,
    ];
    if (free.isEmpty) return;
    late final List<(double, double?)> plan;
    final length = _planDuration;
    if (length <= 0) {
      if (_runs.isNotEmpty) return;
      var from = _position;
      for (final r in mergeRanges(occupied)) {
        if (from >= r.$1 && from < r.$2) from = r.$2;
      }
      plan = reachedEnd ? [] : [(from, runEnd(occupied, from))];
    } else if (_mode == SubtitleMode.follow) {
      final next = nextStart(
        covered: occupied,
        duration: length,
        position: _position,
        mode: _mode,
      );
      if (next != null && next - _position > kFollowAhead) {
        _pauseAt(next);
        return;
      }
      plan = next == null
          ? []
          : [
              (
                next,
                planRuns(
                  covered: occupied,
                  duration: length,
                  position: next,
                  slots: 1,
                ).first.$2,
              ),
            ];
    } else {
      plan = planRuns(
        covered: occupied,
        duration: length,
        position: _position,
        slots: free.length,
      );
    }
    if (plan.isEmpty && _runs.isEmpty) {
      if (!finished) {
        finished = true;
        _retranslate();
        _set(
          cues.isEmpty
              ? 'Đã nghe hết nhưng không thấy lời thoại'
              : 'Đã nghe xong',
        );
      }
      return;
    }
    for (var i = 0; i < plan.length; i++) {
      final r = _Run(free[i], ++_nextGen, plan[i].$1, plan[i].$2);
      _runs[r.slot] = r;
      finished = false;
      r.opening = _startRun(r);
    }
  }

  Future<void> _startRun(_Run r) async {
    try {
      // In particular, release the old native workers before reallocating on a seek.
      await Future.wait(_retiring.toList());
      if (!_owns(r)) return;
      final dir = await Directory(p.join(_root!.path, 'g${r.gen}')).create();
      if (!_owns(r)) {
        await _deleteDir(dir);
        return;
      }
      r.dir = dir;
      final audioDir = await _audioArchive!.createRun(r.gen, r.base);
      r.audioDir = audioDir;
      if (!_owns(r)) return;
      final source = await (_resolving ??= _audioSource());
      if (!_owns(r)) return;
      final releaseExtraction = await VideoPipeline.extraction.acquire(
        videoId,
        cancelled: r.cancelled.future,
      );
      if (!_owns(r)) {
        releaseExtraction();
        return;
      }
      r.releaseExtraction = releaseExtraction;
      final feed = r.feed = _createFeed();
      final end = r.end;
      final stop = end == null
          ? null
          : _planDuration > 0
          ? math.min(_planDuration, end + 2)
          : end;
      AppLog.i(
        'phụ đề',
        'Lượt ${r.slot + 1} từ ${_clock(r.base)} → ${stop == null ? 'hết phim' : _clock(stop)}',
      );
      await feed.start(
        input: source,
        outDir: audioDir.path,
        headers: _hls && !_noRelay ? const {} : headers,
        hls: _hls,
        startSec: r.base,
        lengthSec: stop == null ? null : stop - r.base,
      );
      if (!_owns(r)) {
        await feed.stop();
        return;
      }
      r.extractionPoll = Timer.periodic(const Duration(milliseconds: 400), (
        timer,
      ) {
        if (feed.done || !_owns(r)) {
          timer.cancel();
          r.releaseExtraction?.call();
          r.releaseExtraction = null;
        }
      });
      // Audio extraction can run while another film occupies recognition.
      // Limit native model allocations as well as simultaneous decoding.
      final releaseModel = await VideoPipeline.recognizers.acquire(
        videoId,
        cancelled: r.cancelled.future,
      );
      if (!_owns(r)) {
        releaseModel();
        return;
      }
      r.releaseModel = releaseModel;
      final worker = await _createWorker(language);
      if (!_owns(r)) {
        await worker.dispose();
        return;
      }
      r.worker = worker;
      r.sub = worker.events.listen((e) => _onEvent(r, e));
      worker.reset(r.gen, r.base);
      lastActivity = r.lastChunk = DateTime.now();
      r.poll = Timer.periodic(
        const Duration(milliseconds: 400),
        (_) => _pump(r),
      );
      _set('Đang nghe và dịch…');
    } catch (e, st) {
      if (!_owns(r)) return;
      if (r.slot == 1 && r.worker == null) {
        AppLog.e('phụ đề', 'Không nạp được lượt 2: $e', st);
        didHaveMemoryPressure();
      } else {
        _fail('$e', st);
      }
    }
  }

  void _pump(_Run r) {
    if (!_owns(r) || r.lastSent) return;
    final feed = r.feed!;
    if (waitingTranslation >= 160) {
      r.lastChunk = DateTime.now();
      return;
    }
    if (!feed.done &&
        r.pending == 0 &&
        DateTime.now().difference(r.lastChunk).inSeconds >= 60) {
      _finish(r, 'Không nhận thêm âm thanh trong 60 giây');
      return;
    }
    while (r.pending < 1) {
      final current = File(p.join(r.audioDir!.path, chunkName(r.nextChunk)));
      final next = File(p.join(r.audioDir!.path, chunkName(r.nextChunk + 1)));
      if (!next.existsSync()) {
        if (!feed.done) return;
        r.lastSent = true;
        if (!current.existsSync()) {
          if (r.pending == 0) _finish(r, feed.error ?? '');
          return;
        }
      }
      r.pending++;
      r.nextChunk++;
      _chunksFed++;
      r.lastChunk = DateTime.now();
      unawaited(() async {
        final release = await VideoPipeline.recognition.acquire(
          videoId,
          cancelled: r.cancelled.future,
        );
        if (!_owns(r)) {
          release();
          return;
        }
        r.releaseRecognition = release;
        try {
          // The worker may delete its input. It receives a disposable copy;
          // the original audio remains private until explicit confirmation.
          final working = await current.copy(
            p.join(r.dir!.path, p.basename(current.path)),
          );
          if (!_owns(r)) {
            release();
            return;
          }
          r.worker!.feed(r.gen, working.path, last: r.lastSent);
        } catch (e, st) {
          release();
          r.releaseRecognition = null;
          if (_owns(r)) _fail('$e', st);
        }
      }());
      if (r.lastSent) return;
    }
  }

  void _onEvent(_Run r, AsrEvent event) {
    if (!_owns(r) || event.gen != r.gen && event.gen != -1) return;
    lastActivity = DateTime.now();
    switch (event) {
      case AsrSegment() when isFiller(event.text):
        _fillers++;
      case AsrSegment():
        _linesHeard++;
        final detected = _language.observe(event.lang, event.end - event.start);
        if (detected) {
          _translationEpoch++;
          _translatorReady = false;
        }
        final c = Cue(
          start: event.start,
          end: event.end + 0.4,
          text: event.text,
          source: event.text,
        );
        if (_addCue(c)) {
          final lang = language;
          _cueLanguages[(c.start, c.source)] = lang;
          _queueCue(c, lang);
        }
        if (detected) {
          AppLog.i('phụ đề', 'Đã nhận diện $languageNotice');
          _prepareTranslator();
          unawaited(_replan());
        }
      case AsrProgress():
        r.releaseRecognition?.call();
        r.releaseRecognition = null;
        r.pending--;
        r.processedUntil = event.until;
        if (event.last || (r.lastSent && r.pending <= 0)) {
          _finish(r, r.feed?.error ?? '');
          return;
        }
        if (_mode == SubtitleMode.follow &&
            r.processedUntil - _position >= kFollowAhead) {
          final at = r.processedUntil;
          _retire(r);
          _pauseAt(at);
        }
      case AsrError():
        _fail(event.message, StackTrace.current);
        return;
    }
    if (!_disposed) notifyListeners();
  }

  void _finish(_Run r, String failure) {
    if (!_owns(r)) return;
    r.poll?.cancel();
    r.extractionPoll?.cancel();
    final at = r.processedUntil;
    final tail =
        duration > 0 && r.end == duration && at > r.base && at >= duration - 15;
    if (tail || r.end == null && failure.isEmpty && at > r.base) {
      // The container can run a few seconds longer than its audio track.
      _audioEnd = math.min(at, duration > 0 ? duration : at);
      reachedEnd = true;
      failure = '';
    }
    // A successful but empty/premature EOF should not schedule the same hole forever.
    if (!tail && failure.isEmpty && r.end != null && r.end! - at > 3) {
      failure = 'Âm thanh kết thúc sớm ở ${_clock(at)}';
    }
    if (failure.isNotEmpty) {
      _feedError = failure;
      AppLog.e(
        'ffmpeg',
        failure.length > 1500
            ? failure.substring(failure.length - 1500)
            : failure,
      );
      if (failure.contains('127.0.0.1') && !_noRelay) {
        _noRelay = true;
      } else if (!_fileRelay &&
          !_noRelay &&
          !_hls &&
          Platform.isIOS &&
          input.startsWith('http')) {
        _fileRelay = true;
      }
      final tries = (_retryCount[r.slot] ?? 0) + 1;
      _retryCount[r.slot] = tries;
      if (tries > (at - r.base < 1 ? 2 : 6)) {
        _fail('Mất kết nối ở ${_clock(at)}: $failure', StackTrace.current);
        return;
      }
      _resolving = null;
      _source = null;
      _set('Mất kết nối, đang nối lại (lần $tries)…');
      r.poll = Timer(Duration(seconds: 2 * tries), () {
        if (!_owns(r)) return;
        _retire(r);
        // Reserve this same range during backoff; its sibling keeps working.
        final retry = _Run(r.slot, ++_nextGen, math.max(r.base, at - 2), r.end);
        _runs[r.slot] = retry;
        retry.opening = _startRun(retry);
      });
      return;
    }
    _feedError = '';
    _retryCount.remove(r.slot);
    if (r.end == null || duration > 0 && at >= duration - 1) reachedEnd = true;
    _retire(r);
    _schedule();
    if (!_disposed) notifyListeners();
  }

  void _retire(_Run r) {
    if (!identical(_runs[r.slot], r)) return;
    _runs.remove(r.slot);
    _lastProcessed = r.processedUntil;
    if (r.processedUntil > r.base) _covered.add((r.base, r.processedUntil));
    r.poll?.cancel();
    if (!r.cancelled.isCompleted) r.cancelled.complete();
    r.releaseRecognition?.call();
    r.releaseRecognition = null;
    r.sub?.cancel();
    final workerStopped = r.worker?.dispose();
    final stopping =
        (() async {
          try {
            await r.feed?.stop();
            await workerStopped;
            await r.opening;
          } finally {
            r.releaseExtraction?.call();
            r.releaseExtraction = null;
            r.releaseModel?.call();
            r.releaseModel = null;
            if (r.dir != null) await _deleteDir(r.dir!);
          }
        })().catchError((Object e) {
          AppLog.e('phụ đề', 'Dừng lượt: $e');
        });
    _retiring.add(stopping);
    stopping.whenComplete(() => _retiring.remove(stopping));
  }

  static Future<void> _deleteDir(Directory dir) async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      /* Already removed or still closing. */
    }
  }

  Future<void> _replan() async {
    final epoch = ++_epoch;
    for (final r in _runs.values.toList()) {
      _retire(r);
    }
    paused = false;
    finished = false;
    _resumeAt = null;
    _retryCount.clear();
    await Future.wait(_retiring.toList());
    if (!_disposed && epoch == _epoch) _schedule();
  }

  void _pauseAt(double at) {
    paused = true;
    _resumeAt = at;
    _set('Đã có phụ đề trước chỗ đang xem, tạm nghỉ');
  }

  void _fail(String message, StackTrace st) {
    if (_disposed) return;
    error = message;
    AppLog.e('phụ đề', message, st);
    for (final r in _runs.values.toList()) {
      _retire(r);
    }
    _set('Lỗi: $message');
  }

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
    cueRevision++;
    onCue?.call(cues[i]);
  }

  /// A manual correction invalidates translations still returning under the
  /// old language. Original words and timestamps remain available to revise.
  Future<void> selectLanguage(String code) async {
    if (_disposed) return;
    _language.select(code);
    cueRevision++;
    _translationEpoch++;
    _translations.clear();
    _pendingCues.clear();
    _blockedTranslations.clear();
    _cueLanguages.clear();
    for (final cue in List.of(cues)) {
      if (cue.source.isNotEmpty) {
        _replaceText(cue.start, cue.source, cue.source);
      }
    }
    _translatorReady = false;
    _prepareTranslator();
    if (_root != null) await _replan();
    if (!_disposed) notifyListeners();
  }

  /// Used by revision UI; pending automatic translations must not overwrite
  /// a revision accepted by the viewer.
  void applyCues(List<Cue> replacement) {
    if (_disposed) return;
    _translationEpoch++;
    _pendingCues.clear();
    _translations.clear();
    cues
      ..clear()
      ..addAll(replacement);
    cueRevision++;
    for (final c in cues) {
      onCue?.call(c);
    }
    _retranslate();
    notifyListeners();
  }

  void requestStop() {
    if (_disposed || stopped) return;
    stopped = true;
    _tick?.cancel();
    _translationEpoch++;
    for (final run in _runs.values.toList()) {
      _retire(run);
    }
    unawaited(_translator.dispose());
    notifyListeners();
  }

  bool _addCue(Cue cue) {
    // After seeking back, the same speech can be recognised twice.
    for (final c in cues) {
      final overlap =
          (cue.end < c.end ? cue.end : c.end) -
          (cue.start > c.start ? cue.start : c.start);
      if (overlap > 0.5 * (cue.end - cue.start)) return false;
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
    if (i < cues.length && cue.end > cues[i].start) {
      cue = Cue(
        start: cue.start,
        end: cues[i].start,
        text: cue.text,
        source: cue.source,
      );
    }
    cues.insert(i, cue);
    cueRevision++;
    lastActivity = DateTime.now();
    onCue?.call(cue);
    return true;
  }

  void updatePosition(double t, {double duration = 0}) {
    if (_disposed) return;
    final nowKnown = this.duration <= 0 && duration > 0;
    if (duration > 0) this.duration = duration;
    _position = t;
    if (_translator case final OpenRouterTranslator cloud) cloud.position = t;
    if (_translator case final MlKitTranslator local) local.position = t;
    if (_root == null || error != null) return;
    if (nowKnown) {
      unawaited(_replan());
      return;
    }
    if (paused &&
        _resumeAt != null &&
        t >= _resumeAt! - kFollowResume &&
        t <= _resumeAt! + kSeekJump) {
      unawaited(_replan());
      return;
    }
    if (covered.any((r) => t >= r.$1 - 1 && t <= r.$2 - 2) ||
        _runs.values.any(
          (r) => t >= r.base - 1 && t <= r.processedUntil + kSeekJump,
        )) {
      _outOfRange = 0;
      return;
    }
    if (finished && _mode == SubtitleMode.whole) return;
    if ((t - _seekTarget).abs() >= 2) _outOfRange = 0;
    _seekTarget = t;
    if (++_outOfRange < 3 ||
        DateTime.now().difference(_lastSeekRestart).inSeconds < 3) {
      return;
    }
    _outOfRange = 0;
    _lastSeekRestart = DateTime.now();
    AppLog.i('phụ đề', 'Tua tới ${_clock(t)}, làm từ đó');
    unawaited(_replan());
  }

  Cue? at(double t) => cueAt(cues, t);
  double leadOver(double t) {
    for (final r in covered) {
      if (r.$1 <= t && t <= r.$2) return r.$2 - t;
    }
    return -1;
  }

  static String _clock(double s) {
    final t = s.round();
    String two(int v) => v.toString().padLeft(2, '0');
    return t >= 3600
        ? '${t ~/ 3600}:${two(t ~/ 60 % 60)}:${two(t % 60)}'
        : '${t ~/ 60}:${two(t % 60)}';
  }

  String get _runSummary => [
    for (final r
        in _runs.values.toList()..sort((a, b) => a.slot.compareTo(b.slot)))
      'Lượt ${r.slot + 1}: ${_clock(r.processedUntil)} → ${r.end == null ? 'hết phim' : _clock(r.end!)}',
  ].join(' · ');

  String get stage {
    final tr = _translator.status;
    return [
      if (error != null || paused || _runs.isEmpty || _feedError.isNotEmpty)
        status
      else if (_runs.values.every((r) => r.worker == null))
        'Đang nạp bộ nhận dạng'
      else if (_chunksFed == 0)
        'Đang lấy âm thanh'
      else
        'Đang nhận dạng',
      if (_runs.isNotEmpty) _runSummary,
      if (tr.state != TranslationState.ready &&
          tr.state != TranslationState.disabled)
        tr.description
      else if (waitingTranslation > 0)
        'Chờ dịch $waitingTranslation câu',
      if (tr.blocked > 0) 'Bị chặn ${tr.blocked} câu',
      if (translatorNote.isNotEmpty) translatorNote,
      ?_prepareError,
    ].join(' · ');
  }

  List<SessionStep> get steps {
    final tr = _translator.status;
    final disabled = tr.state == TranslationState.disabled;
    final waitingForPack = !_translatorReady && !disabled
        ? cues.where((c) => c.source.isNotEmpty && c.source == c.text).length
        : 0;
    final translating =
        waitingTranslation > 0 ||
        tr.queued > 0 ||
        tr.inFlight > 0 ||
        waitingForPack > 0;
    final unavailable =
        tr.state == TranslationState.unavailable || _prepareError != null;
    final translated = cues
        .where((c) => c.source.isNotEmpty && c.source != c.text)
        .length;
    final translationDetail = [
      'Đã dịch $translated',
      if (unavailable)
        tr.note.isEmpty ? _lastTranslateError : tr.note
      else if (waitingForPack > 0)
        '$waitingForPack câu chờ bộ dịch sẵn sàng · ${tr.description}'
      else if (tr.state == TranslationState.ready && !translating)
        finished ? 'đã hết câu' : 'chờ câu từ bước nhận dạng'
      else
        tr.description,
      if (tr.queued > 0 && tr.state != TranslationState.gathering)
        'chờ ${tr.queued} câu',
      if (_translateFailures > 0 || tr.failed > 0)
        'lỗi ${math.max(_translateFailures, tr.failed)}',
      if (tr.blocked > 0) 'bị chặn ${tr.blocked} câu',
      if (translatorNote.isNotEmpty) translatorNote,
    ].join(' · ');
    final host = Uri.tryParse(input)?.host ?? '';
    final workers = _runs.values.where((r) => r.worker != null).length;
    final failed = error != null;
    StageState progress(bool ready, bool active) => ready
        ? StageState.done
        : failed
        ? StageState.failed
        : active
        ? StageState.active
        : StageState.waiting;
    return [
      SessionStep(
        'Tìm video trên trang',
        StageState.done,
        host.isEmpty ? 'File trong máy' : host,
      ),
      SessionStep(
        'Nạp bộ nhận dạng giọng nói',
        progress(workers > 0 || finished || paused, true),
        workers > 0
            ? '$workers bộ nhận dạng SenseVoice'
            : finished || paused
            ? 'Đã nạp'
            : 'Đang nạp mô hình…',
      ),
      SessionStep(
        'Chuẩn bị bộ dịch',
        disabled
            ? StageState.skipped
            : unavailable
            ? StageState.failed
            : tr.state == TranslationState.downloading
            ? StageState.active
            : progress(_translatorReady, true),
        unavailable
            ? (tr.note.isEmpty ? _lastTranslateError : tr.note)
            : disabled || tr.state == TranslationState.downloading
            ? tr.description
            : _translatorReady
            ? 'Bộ dịch sẵn sàng'
            : 'Đang chuẩn bị bộ dịch',
      ),
      SessionStep(
        'Kết nối luồng âm thanh',
        progress(_source != null, workers > 0),
        _source == null
            ? workers == 0
                  ? 'Chờ bộ nhận dạng'
                  : 'Đang mở nguồn âm thanh'
            : _hls
            ? 'Luồng HLS'
            : 'Đã mở nguồn',
      ),
      SessionStep(
        'Lấy âm thanh (ffmpeg)',
        progress(finished || paused, _runs.values.any((r) => r.feed != null)),
        '$_chunksFed đoạn · ${_feedError.isNotEmpty
            ? status
            : _chunksFed == 0
            ? 'chờ âm thanh từ video'
            : _runSummary}',
      ),
      SessionStep(
        'Nhận dạng giọng nói',
        progress(finished || paused, _chunksFed > 0),
        '$_linesHeard câu · ${_chunksFed == 0 ? 'chờ đoạn âm thanh' : _runSummary}',
      ),
      SessionStep(
        'Dịch sang tiếng Việt',
        disabled
            ? StageState.skipped
            : unavailable
            ? StageState.failed
            : translating ||
                  _linesHeard > 0 && !finished ||
                  tr.state == TranslationState.gathering
            ? StageState.active
            : finished
            ? StageState.done
            : StageState.waiting,
        translationDetail,
      ),
    ];
  }

  String get details => [
    stage,
    languageNotice,
    'Video: $videoId',
    'Nguồn video: ${AppLog.url(input)}',
    for (final step in steps) '${step.title}: ${step.detail}',
    'Bỏ qua $_fillers tiếng đệm',
    if (_lastTranslateError.isNotEmpty) _lastTranslateError,
    if (_feedError.isNotEmpty) _feedError,
    if (_proxy?.lastError case final String why when why.isNotEmpty) why,
    ?error,
  ].join('\n');

  void _set(String s) {
    status = s;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    for (final r in _runs.values.toList()) {
      _retire(r);
    }
    unawaited(_translator.dispose());
    _proxy?.close();
    final root = _root;
    if (root != null) {
      Future.wait(_retiring.toList()).then((_) => _deleteDir(root));
    }
    unawaited(closeAudio());
    super.dispose();
  }
}
