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
import 'audio_availability.dart';
import 'full_audio_download.dart';

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
  _Run(this.slot, this.gen, this.base, this.end, {this.retained})
    : processedUntil = base;
  final List<RetainedAudioChunk>? retained;
  final int slot, gen;
  final double base;
  final double? end;
  double processedUntil;
  AsrWorker? worker;
  Future<void>? opening;
  StreamSubscription<AsrEvent>? sub;
  Directory? dir;
  Timer? poll;
  DateTime lastChunk = DateTime.now();
  int pending = 0, nextChunk = 0;
  bool lastSent = false;
  String phase = 'Đang chuẩn bị âm thanh';

  /// Queued for a recogniser (another film's stretch is more urgent).
  bool waitingSlot = false;
  void Function()? releaseRecognition;
  void Function()? releaseModel;
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
    this.retainedOnly = false,
    this._retainedInput,
  }) : videoId = videoId ?? input,
       _language = VideoLanguage(
         saved?.language.isNotEmpty == true ? saved!.language : language,
       ),
       _parallel = parallel ?? appSettings.parallelSubtitles,
       _translator = translator ?? Translator.create(videoId: videoId ?? input),
       _createWorker = createWorker ?? _spawn,
       _usesDefaultWorker = createWorker == null,
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
  final bool retainedOnly;
  final bool _usesDefaultWorker;
  bool _recognitionReady = false;
  FullAudioDownload? _download;
  Future<void>? _audioTask;
  RetainedAudioLease? _retainedInput;
  bool needsAudioSource = false;
  String audioTitle = '';
  String audioPage = '';
  bool audioHidden = false;
  AudioArchive? _audioArchive;
  Future<AudioArchive>? _audioOpening;
  Future<void>? _audioClosing;
  bool _audioCompleted = false;

  Future<void> markAudioCompleted() async {
    await _retainedInput?.markCompleted();
    if (retainedOnly) {
      return;
    }
    if (_audioCompleted || _audioArchive == null) return;
    _audioCompleted = true;
    try {
      await _audioArchive!.update(completed: true);
      _availableAudio = await audioStore.availability(
        videoId,
        duration: duration,
        includeHidden: audioHidden,
      );
      if (!_disposed) notifyListeners();
    } catch (_) {
      _audioCompleted = false;
      rethrow;
    }
  }

  Future<void> closeAudio() => _audioClosing ??= () async {
    await _download?.close();
    await _audioTask;
    await Future.wait(_retiring.toList());
    await _retainedInput?.close();
    if (retainedOnly) {
      return;
    }
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
  final _translations = <String, Future<String?>>{};
  final _blockedTranslations = <String>{};
  final _failedTranslations = <String>{};
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
  bool retrying = false;

  bool get canRetry =>
      !_disposed &&
      !stopped &&
      (error != null ||
          _prepareError != null ||
          _failedTranslations.isNotEmpty ||
          activity == SessionActivity.stuck);

  /// Resume missing ranges and failed lines without discarding completed work.
  Future<void> retry() async {
    if (!canRetry || retrying) return;
    retrying = true;
    final previousStatus = status;
    final restartAudio = error != null || activity == SessionActivity.stuck;
    _set('Đang thử lại…');
    try {
      if (restartAudio) {
        ++_epoch;
        for (final run in _runs.values.toList()) {
          _retire(run);
        }
        await Future.wait(_retiring.toList());
        if (_disposed || stopped) return;
        _resolving = null;
        _source = null;
        _feedError = '';
        error = null;
        finished = false;
        paused = false;
        _resumeAt = null;
        await _initializeStorage();
        if (_disposed || stopped) return;
        _schedule();
      }
      _translationEpoch++;
      _translations.clear();
      _pendingCues.clear();
      _blockedTranslations.clear();
      _failedTranslations.clear();
      _prepareError = null;
      _lastTranslateError = '';
      _translateFailures = 0;
      _translatorReady = false;
      _prepareTranslator();
      if (!restartAudio) status = previousStatus;
      lastActivity = DateTime.now();
    } catch (e, st) {
      _fail('$e', st);
    } finally {
      retrying = false;
      if (!_disposed) notifyListeners();
    }
  }

  DateTime lastActivity = DateTime.now(), _lastSeekRestart = DateTime(0);
  Directory? _root;
  Timer? _tick;
  bool _readingAudio = false;
  AudioAvailability _availableAudio = AudioAvailability();
  AudioAvailability get audioAvailability =>
      _availableAudio.withDuration(duration);
  bool get downloadingAudio => _download?.downloading ?? false;
  int get translatedCount =>
      cues.where((c) => c.source.isEmpty || c.text != c.source).length;
  Future<String>? _resolving;
  String? _source;
  String _feedError = '';
  double? _resumeAt;

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
    if (!_recognitionReady && _audioTask != null) {
      return SessionActivity.working;
    }
    if (finished &&
        waitingTranslation == 0 &&
        (_prepareError != null || _failedTranslations.isNotEmpty)) {
      return SessionActivity.failed;
    }
    if (finished &&
        waitingTranslation == 0 &&
        (_translatorReady ||
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

  /// No completion while a translation, failed line or final audio range remains.
  bool get readyToFinish =>
      !_disposed &&
      !stopped &&
      !retrying &&
      activity == SessionActivity.done &&
      _prepareError == null &&
      _failedTranslations.isEmpty &&
      coversWholeVideo(covered, duration, reachedEnd: reachedEnd);

  double get progressFraction {
    final recognized = duration > 0
        ? (coveredSeconds(covered) / duration).clamp(0.0, 1.0)
        : finished
        ? 1.0
        : 0.0;
    final translated = cues.isEmpty
        ? 0.0
        : cues.where((c) => c.source.isEmpty || c.text != c.source).length /
              cues.length;
    return readyToFinish
        ? 1
        : ((audioAvailability.fraction ?? 0) * 0.45 +
                  recognized * 0.45 +
                  translated * 0.1)
              .clamp(0.0, 0.9999);
  }

  void reportSaveFailure(Object error) =>
      _fail('Chưa lưu xong phụ đề: $error', StackTrace.current);

  bool _foreground = false;

  /// The video is on screen (the browser tab or player showing it): its
  /// stretch ahead of the viewer comes before every other film's work.
  bool get foreground => _foreground;
  set foreground(bool value) {
    if (_foreground == value || _disposed) return;
    _foreground = value;
    VideoPipeline.recognizers.reprioritize();
    notifyListeners();
  }

  bool _preferred = false;

  /// The user put this film first: its work takes the recognisers before
  /// any film that is not preferred, on screen or not.
  bool get preferred => _preferred;
  set preferred(bool value) {
    if (_preferred == value || _disposed) return;
    _preferred = value;
    AppLog.i(
      'phụ đề',
      '${value ? 'Ưu tiên' : 'Bỏ ưu tiên'} ${audioTitle.isEmpty ? videoId : audioTitle}',
    );
    VideoPipeline.recognizers.reprioritize();
    notifyListeners();
  }

  /// 0: just ahead of the viewer of a video on screen; 1: the rest ahead of
  /// it; 2: background (other films, stretches behind). A preferred film
  /// comes before all of these (-3 to -1).
  int _priorityOf(_Run r) {
    final int base;
    if (!_foreground) {
      base = 2;
    } else {
      final end = r.end ?? double.infinity;
      final ahead = end > _position && r.base <= _position + 180;
      base = ahead ? 0 : 1;
    }
    return _preferred ? base - 3 : base;
  }

  /// A more urgent stretch needs this recogniser: stop at the current
  /// piece (what is done stays done) and queue the rest again.
  void _yieldRun(_Run r) {
    if (!_owns(r)) return;
    AppLog.i(
      'phụ đề',
      'Lượt ${r.slot + 1} nhường bộ nhận dạng ở ${_clock(r.processedUntil)}',
    );
    _retire(r);
    _schedule();
    notifyListeners();
  }

  String? _liveInput;
  Map<String, String>? _liveHeaders;
  final _oldProxies = <HlsProxy>[];

  /// The page gave this video a new address (signed links change on every
  /// visit and expire): runs from now on fetch through it. Work already
  /// done is kept; nothing restarts.
  void updateSource(String src, {Map<String, String>? headers}) {
    if (_disposed || src.isEmpty || src == (_liveInput ?? input)) return;
    AppLog.i('phụ đề', 'Video có địa chỉ mới, các lượt sau dùng địa chỉ này');
    _liveInput = src;
    if (headers != null) _liveHeaders = headers;
    _source = null;
    _resolving = null;
    // Runs in progress keep their relay; new ones get one with the new
    // headers. Old relays close with the session.
    final proxy = _proxy;
    if (proxy != null && headers != null) {
      _oldProxies.add(proxy);
      _proxy = null;
    }
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
      // Give back run 2's recogniser before there is only one: otherwise
      // lowering the count may make run 1 (the stretch being watched)
      // give way instead, whichever of the two happened to start last.
      final release = second.releaseModel;
      second.releaseModel = null;
      _retire(second);
      release?.call();
    }
    VideoPipeline.recognizers.capacity = 1;
    if (second != null) {
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
    try {
      await _initializeStorage();
      if (!_disposed && !stopped) _schedule();
    } catch (e, st) {
      _fail('$e', st);
    }
  }

  Future<void> _downloadThenRecognize() async {
    final download = _download = FullAudioDownload(
      videoId: videoId,
      store: audioStore,
      archive: _audioArchive!,
      duration: () => duration,
      source: () => _resolving ??= _audioSource(),
      headers: () => _hls && !_noRelay ? const {} : (_liveHeaders ?? headers),
      hls: () => _hls,
      createFeed: _createFeed,
      nextGeneration: () => ++_nextGen,
      hidden: audioHidden,
      onProgress: (audio) {
        if (_disposed || stopped) return;
        if (audio.seconds > _availableAudio.seconds + .001) {
          lastActivity = DateTime.now();
        }
        _availableAudio = audio;
        notifyListeners();
      },
      onStatus: (message) {
        if (!_disposed && !stopped) _set(message);
      },
      onRetry: (failure) {
        _resolving = null;
        _source = null;
        if (failure.contains('127.0.0.1') && !_noRelay) {
          _noRelay = true;
        } else if (!_fileRelay &&
            !_noRelay &&
            !_hls &&
            Platform.isIOS &&
            input.startsWith('http')) {
          _fileRelay = true;
        }
      },
    );
    try {
      final lease = await download.run();
      if (_disposed || stopped || lease == null) {
        await lease?.close();
        return;
      }
      await _retainedInput?.close();
      _retainedInput = lease;
      _availableAudio = lease.availability(duration: duration);
      _recognitionReady = true;
      needsAudioSource = false;
      _set('Đã tải đủ âm thanh · bắt đầu nhận dạng và dịch');
      _prepareTranslator();
      _schedule();
    } catch (e, st) {
      if (!_disposed && !stopped) _fail('Chưa tải đủ âm thanh: $e', st);
    } finally {
      _audioTask = null;
    }
  }

  Future<void> _initializeStorage() async {
    if (_root == null) {
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
    }
    if (retainedOnly) {
      _retainedInput ??= await audioStore.acquire(
        videoId,
        includeHidden: audioHidden,
      );
      _availableAudio =
          _retainedInput?.availability(duration: duration) ??
          AudioAvailability(duration: duration);
      return;
    }
    if (_audioArchive == null && !_disposed && !stopped) {
      _audioOpening = audioStore.create(
        videoId,
        title: audioTitle,
        hidden: audioHidden,
        source: input,
        page: audioPage,
        language: language,
        duration: duration,
      );
      _audioArchive = await _audioOpening;
      await _refreshAudioAvailability();
      if (_disposed || stopped) {
        await closeAudio();
        return;
      }
    }
  }

  Future<void> _refreshAudioAvailability() async {
    if (_readingAudio || _disposed || stopped) return;
    _readingAudio = true;
    try {
      final available = await audioStore.availability(
        videoId,
        duration: duration,
        includeHidden: audioHidden,
      );
      if (_disposed || stopped) return;
      if (available.seconds > _availableAudio.seconds + 0.01) {
        lastActivity = DateTime.now();
      }
      _availableAudio = available;
      notifyListeners();
    } catch (e) {
      AppLog.e('âm thanh', 'Chưa kiểm tra được phần âm thanh đã lưu: $e');
    } finally {
      _readingAudio = false;
    }
  }

  void _prepareTranslator() {
    if (!_recognitionReady) return;
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
        if (text != null) _failedTranslations.remove(key);
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
    final epoch = _translationEpoch;
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
      if (_disposed ||
          epoch != _translationEpoch ||
          e is TranslationCancelled ||
          engine != _translator) {
        return null;
      }
      if (e is OpenRouterError && (e.blocked || e.permanent)) {
        _blockedTranslations.add('$lang|${c.source}');
      }
      _translateFailures++;
      _failedTranslations.add('$lang|${c.source}');
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
    final input = _liveInput ?? this.input;
    final headers = _liveHeaders ?? this.headers;
    if (!input.startsWith('http')) return _source = input;
    final resolved = await resolveAudioSource(
      input,
      headers,
      language: language == 'auto' ? '' : language,
    );
    if (_disposed || stopped) throw const TranslationCancelled();
    _hls = '$resolved $input'.contains('m3u8');
    if (_noRelay) return _source = resolved;
    // A plain file is read by ffmpeg directly (one fast stream); the relay
    // (small ranged reads through iOS networking) only once the server has
    // turned ffmpeg away.
    if (!_hls && !_fileRelay) return _source = resolved;
    // HLS goes through the relay, which strips fake picture headers.
    final proxy = _proxy ??= await HlsProxy.start(headers);
    if (_disposed || stopped) {
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
    if (!_recognitionReady) {
      final ranges = covered;
      final textOnly =
          ranges.length == 1 &&
          ranges.single.$1 <= .001 &&
          (duration > 0 ? ranges.single.$2 >= duration - .001 : reachedEnd);
      if (textOnly || retainedOnly && audioAvailability.complete) {
        _recognitionReady = true;
        _prepareTranslator();
      } else if (retainedOnly) {
        needsAudioSource = true;
        paused = true;
        _set('Cần tải đủ âm thanh trước khi nhận dạng và dịch');
        return;
      } else {
        _audioTask ??= _downloadThenRecognize();
        return;
      }
    }
    _scheduleRetained();
  }

  void _scheduleRetained() {
    final free = [
      for (var i = 0; i < _slots; i++)
        if (!_runs.containsKey(i)) i,
    ];
    final plans = planRetainedAudio(
      _retainedInput?.chunks ?? const [],
      covered,
      [for (final r in _runs.values) (r.base, r.end!)],
      free.length,
      position: _position,
    );
    if (plans.isEmpty && _runs.isEmpty) {
      final ranges = covered;
      final audioEnd = _retainedInput?.endOfAudio;
      final target = audioEnd ?? duration;
      final whole =
          ranges.length == 1 &&
          ranges.single.$1 < 0.06 &&
          (target > 0 ? ranges.single.$2 >= target - 0.06 : reachedEnd);
      if (whole) {
        finished = true;
        if (audioEnd != null) reachedEnd = true;
        needsAudioSource = false;
        _retranslate();
        _set('Đã nhận dạng xong từ âm thanh đã lưu');
      } else {
        needsAudioSource = true;
        paused = true;
        _retranslate();
        _set(
          'Đã xử lý hết âm thanh đã lưu. Còn thiếu âm thanh của một số đoạn.',
        );
      }
      return;
    }
    for (var i = 0; i < plans.length; i++) {
      final chunks = plans[i];
      needsAudioSource = false;
      final run = _Run(
        free[i],
        ++_nextGen,
        chunks.first.start,
        chunks.last.end,
        retained: chunks,
      );
      _runs[run.slot] = run;
      finished = false;
      run.opening = _startRun(run);
    }
  }

  Future<void> _startRun(_Run r) async {
    try {
      await Future.wait(_retiring.toList());
      if (!_owns(r)) return;
      final dir = await Directory(p.join(_root!.path, 'g${r.gen}')).create();
      if (!_owns(r)) {
        await _deleteDir(dir);
        return;
      }
      r.dir = dir;
      await _openWorker(r);
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

  Future<void> _openWorker(_Run r) async {
    r.waitingSlot = true;
    r.phase = 'Đang chờ lượt nhận dạng';
    notifyListeners();
    final releaseModel = await VideoPipeline.recognizers.acquire(
      priority: () => _priorityOf(r),
      onPreempt: () => _yieldRun(r),
      cancelled: r.cancelled.future,
    );
    r.waitingSlot = false;
    if (!_owns(r)) {
      releaseModel();
      return;
    }
    r.releaseModel = releaseModel;
    r.phase = 'Đang nạp bộ nhận dạng';
    notifyListeners();
    if (_usesDefaultWorker && !await ModelStore.isReady()) {
      await ModelStore.download((progress) {
        if (_owns(r)) {
          r.phase =
              'Đang tải bộ nhận dạng: ${(progress * 100).floor()}% · âm thanh đã tải đủ';
          lastActivity = DateTime.now();
          _set(r.phase);
        }
      });
      if (!_owns(r)) return;
    }
    final worker = await _createWorker(language);
    if (!_owns(r)) {
      await worker.dispose();
      return;
    }
    r.worker = worker;
    r.sub = worker.events.listen((e) => _onEvent(r, e));
    worker.reset(r.gen, r.base);
    lastActivity = r.lastChunk = DateTime.now();
    r.poll = Timer.periodic(const Duration(milliseconds: 400), (_) => _pump(r));
    _set(
      r.retained == null
          ? 'Đang nghe và dịch…'
          : 'Đang nhận dạng và dịch âm thanh đã lưu…',
    );
  }

  void _pump(_Run r) {
    if (!_owns(r) || r.lastSent) return;
    _pumpRetained(r);
  }

  void _pumpRetained(_Run r) {
    if (r.pending > 0 || waitingTranslation >= 160) return;
    final chunks = r.retained!;
    if (r.nextChunk >= chunks.length) return;
    final index = r.nextChunk++;
    final chunk = chunks[index];
    r.pending++;
    _chunksFed++;
    r.lastSent = r.nextChunk == chunks.length;
    unawaited(() async {
      try {
        final working = await chunk.file.copy(
          p.join(r.dir!.path, chunkName(index)),
        );
        if (!_owns(r)) return;
        r.worker!.feed(r.gen, working.path, last: r.lastSent);
      } catch (e, st) {
        if (_owns(r)) {
          needsAudioSource = true;
          _fail('Không đọc được âm thanh đã lưu: $e', st);
        }
      }
    }());
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
          _finish(r, '');
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
    if (failure.isNotEmpty) {
      _fail(
        'Không nhận dạng được âm thanh đã lưu: $failure',
        StackTrace.current,
      );
      return;
    }
    final target = _retainedInput?.endOfAudio ?? duration;
    if (target > 0 && r.processedUntil >= target - .001) reachedEnd = true;
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
            await workerStopped;
            await r.opening;
          } finally {
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
    _failedTranslations.clear();
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
    _failedTranslations.retainAll({
      for (final c in replacement)
        if (c.source.isNotEmpty && c.text == c.source) '$language|${c.source}',
    });
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
    _download?.cancel();
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
    if (_foreground && VideoPipeline.recognizers.waiting > 0) {
      VideoPipeline.recognizers.reprioritize();
    }
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
      else if (_runs.values.isNotEmpty &&
          _runs.values.every((r) => r.waitingSlot))
        _foreground
            ? 'Đang chờ bộ nhận dạng'
            : 'Đang nhường máy cho video đang xem'
      else if (_runs.values.every((r) => r.worker == null))
        _runs.values.first.phase
      else if (_chunksFed == 0)
        retainedOnly
            ? 'Đang đọc âm thanh đã lưu'
            : 'Đang chờ đoạn âm thanh đầu tiên'
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
    final loadingWorker = _runs.values.any(
      (r) => !r.waitingSlot && r.worker == null,
    );
    final connectingAudio = _download?.connecting ?? false;
    final readLocal =
        retainedOnly || _recognitionReady && _retainedInput != null;
    final textOnly = retainedOnly && _retainedInput?.chunks.isEmpty == true;
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
        textOnly
            ? StageState.skipped
            : progress(workers > 0 || finished, loadingWorker),
        textOnly
            ? 'Không cần nhận dạng lại'
            : workers > 0
            ? '$workers bộ nhận dạng SenseVoice'
            : finished
            ? 'Đã nạp'
            : loadingWorker
            ? 'Đang nạp mô hình…'
            : 'Chờ lượt nhận dạng',
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
        readLocal ? 'Đọc âm thanh trong app' : 'Kết nối luồng âm thanh',
        readLocal
            ? audioAvailability.seconds > 0
                  ? StageState.done
                  : StageState.skipped
            : progress(_source != null, connectingAudio),
        readLocal
            ? 'Dùng file đã lưu, không kết nối lại trang web'
            : _source == null
            ? connectingAudio
                  ? 'Đang kết nối nguồn âm thanh'
                  : 'Chờ mở nguồn âm thanh'
            : _hls
            ? 'Luồng HLS'
            : 'Đã mở nguồn',
      ),
      SessionStep(
        'Tải và lưu âm thanh',
        audioAvailability.complete
            ? StageState.done
            : needsAudioSource || failed
            ? StageState.failed
            : downloadingAudio
            ? StageState.active
            : retainedOnly
            ? StageState.skipped
            : StageState.waiting,
        '${audioAvailability.label}${needsAudioSource ? ' · còn thiếu từ ${AudioAvailability.clock(audioAvailability.firstMissing)}' : ''}',
      ),
      SessionStep(
        'Nhận dạng giọng nói',
        progress(finished, _chunksFed > 0 && !paused),
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
    _download?.cancel();
    if (_started) WidgetsBinding.instance.removeObserver(this);
    _tick?.cancel();
    for (final r in _runs.values.toList()) {
      _retire(r);
    }
    unawaited(_translator.dispose());
    _proxy?.close();
    for (final old in _oldProxies) {
      old.close();
    }
    final root = _root;
    if (root != null) {
      Future.wait(_retiring.toList()).then((_) => _deleteDir(root));
    }
    unawaited(closeAudio());
    super.dispose();
  }
}
