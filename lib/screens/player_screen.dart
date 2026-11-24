import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../widgets/session_retry.dart';
import '../services/bookmarks.dart';
import '../models/cue.dart';
import '../services/active_work.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/crash_trail.dart';
import '../services/keep_awake.dart';
import '../services/subtitle_session.dart';
import '../services/subtitle_store.dart';
import '../services/video_library.dart';
import '../services/watch_position.dart';
import '../widgets/activity_icon.dart';
import '../widgets/common.dart';
import '../widgets/subtitle_details.dart';
import '../widgets/subtitle_import.dart';
import '../widgets/subtitle_style.dart';
import '../widgets/subtitle_revision.dart';
import '../widgets/video_language.dart';
import 'export_sheet.dart';
import 'retained_audio_screen.dart';

/// Plays a library video or a stream found in the browser, with subtitles
/// drawn by the app (so they also show in full screen) and speed up to 2.5x.
class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.title,
    this.item,
    this.url,
    this.headers = const {},
    this.startAt = 0,
    this.autoSubtitles = false,
    this.page,
  }) : assert(item != null || url != null);

  final String title;
  final VideoItem? item;
  final String? url;
  final Map<String, String> headers;
  final double startAt;
  final bool autoSubtitles;

  /// Web page the stream came from; its subtitles are kept in the store.
  final String? page;

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  late final VideoPlayerController _player;
  SubtitleSession? _session;
  SessionSaver? _saver;

  /// Current lines came from a subtitle file.
  bool _fromFile = false;
  bool _canResume = false;
  List<Cue> _cues = [];
  bool _showSubs = true;
  bool _showControls = true;
  bool _saved = false;
  double _speed = 1;
  String? _error;
  Timer? _hide;
  Cue? _cue;
  double? _dragging;
  DateTime _lastPositionSave = DateTime(0);
  String _notifiedLanguage = '';

  /// Where the watch position of this video is kept.
  String? get _positionKey => widget.item != null
      ? 'file:${widget.item!.file.absolute.path}'
      : widget.page == null
      ? null
      : SubtitleStore.idForVideo(widget.page!, _input);

  /// Where the place in the film is kept: per page for web videos (with
  /// the length check WatchPosition does), like the browser, so a new
  /// signed video address does not lose it.
  String? get _watchKey => widget.item != null
      ? _positionKey
      : widget.page == null
      ? null
      : SubtitleStore.idFor(widget.page!);

  String get _input => widget.item?.file.path ?? widget.url!;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    appSettings.addListener(_onSettings);
    ActiveWork.all.addListener(_onWorks);
    _player = widget.item != null
        ? VideoPlayerController.file(widget.item!.file)
        : VideoPlayerController.networkUrl(
            Uri.parse(widget.url!),
            httpHeaders: widget.headers,
          );
    _player.addListener(_onTick);
    _init();
  }

  Future<void> _init() async {
    try {
      await CrashTrail.guard(
        'Mở video bằng trình phát',
        () => _player.initialize(),
      );
      final key = _watchKey;
      final resume = widget.startAt > 1 || key == null
          ? null
          : await WatchPosition.load(key, duration: _duration);
      final start = widget.startAt > 1 ? widget.startAt : resume ?? 0;
      if (start > 1) {
        await _player.seekTo(Duration(milliseconds: (start * 1000).round()));
      }
      if (resume != null && mounted) {
        toast(context, 'Xem tiếp từ ${formatTime(resume)}');
      }
      await _player.play();
      final item = widget.item;
      final page = widget.page;
      if (item != null) {
        final saved = await VideoLibrary.loadCues(item);
        final state = await VideoLibrary.loadSubtitleState(item);
        if (saved.isNotEmpty && mounted) {
          setState(() {
            _cues = saved;
            _saved = state?.isWholeVideo ?? true;
            _canResume = state?.canResume ?? false;
            _fromFile = state?.imported ?? false;
          });
        }
      } else if (page != null) {
        final saved = await SubtitleStore.loadVideo(
          page,
          _input,
          duration: _duration,
          pageTitle: widget.title,
        );
        if (saved != null && saved.cues.isNotEmpty && mounted) {
          setState(() {
            _cues = saved.cues;
            _saved = true;
            _fromFile = saved.imported;
            _canResume = saved.canResume;
          });
        }
      }
      final running = ActiveWork.find(_positionKey ?? _input);
      if (running != null && mounted) _attachWork(running);
      if (mounted) setState(() {});
      if (widget.autoSubtitles && (_cues.isEmpty || _canResume)) {
        _startSubtitles();
      }
      if (!mounted) return;
      _scheduleHide();
    } catch (e, st) {
      AppLog.e('trình phát', 'Không phát được: $e', st);
      if (mounted) setState(() => _error = 'Không phát được video này.\n$e');
    }
  }

  double get _position => _player.value.position.inMilliseconds / 1000;
  double get _duration => _player.value.duration.inMilliseconds / 1000;

  /// Stopped from the subtitle store: keep showing the lines made so far,
  /// let go of the disposed session.
  void _onWorks() {
    final session = _session;
    if (session == null ||
        (!ActiveWork.wasStopped(session) && !ActiveWork.wasCompleted(session))) {
      return;
    }
    session.removeListener(_onSession);
    if (!mounted) return;
    setState(() {
      _cues = List.of(session.cues);
      _session = null;
      _saver = null;
      _canResume = !ActiveWork.wasCompleted(session);
      if (ActiveWork.wasCompleted(session)) _saved = true;
    });
  }

  void _onSettings() {
    _session?.parallel = appSettings.parallelSubtitles;
    _session?.mode = widget.item != null || appSettings.subWhole
        ? SubtitleMode.whole
        : SubtitleMode.follow;
    if (mounted) setState(() {});
  }

  void _savePosition({bool now = false}) {
    final key = _watchKey;
    if (key == null || !_player.value.isInitialized) return;
    final time = DateTime.now();
    if (!now && time.difference(_lastPositionSave).inSeconds < 5) return;
    _lastPositionSave = time;
    WatchPosition.save(key, _position, _duration);
  }

  void _onTick() {
    if (!mounted) return;
    final t = _position;
    _savePosition();
    _session?.foreground = true;
    _session?.updatePosition(t, duration: _duration);
    final cue = _showSubs ? cueAt(_cues, t) : null;
    if (!identical(cue, _cue) || _showControls) setState(() => _cue = cue);
  }

  Future<void> _startSubtitles() async {
    if (_session != null) return;
    final running = ActiveWork.find(_positionKey ?? _input);
    if (running != null) {
      _attachWork(running);
      return;
    }
    final page = widget.item == null ? widget.page : null;
    final saved = page == null
        ? await VideoLibrary.loadSubtitleState(widget.item!)
        : await SubtitleStore.loadVideo(
            page,
            _input,
            duration: _duration,
            pageTitle: widget.title,
          );
    if (!mounted || _session != null) return;
    if (saved != null && saved.imported) {
      setState(() {
        _fromFile = true;
        _cues = saved.cues;
        _showSubs = true;
        _canResume = false;
      });
      return;
    }
    if (!await ensureModels(context)) return;
    if (!mounted || _session != null) return;
    final storedLanguage = widget.item == null
        ? ''
        : await VideoLibrary.subtitleLanguage(widget.item!);
    if (!mounted || _session != null) return;
    final alreadyRunning = ActiveWork.find(_positionKey ?? _input);
    if (alreadyRunning != null) {
      _attachWork(alreadyRunning);
      return;
    }
    final session = SubtitleSession(
      input: _input,
      videoId: _positionKey ?? _input,
      language: storedLanguage.isEmpty ? appSettings.language : storedLanguage,
      headers: widget.headers,
      saved: saved,
      initialCues: page == null ? _cues : const [],
      // A library file is local: making all of it costs no data.
      mode: appSettings.subWhole || widget.item != null
          ? SubtitleMode.whole
          : SubtitleMode.follow,
    )..addListener(_onSession);
    session.duration = _duration;
    if (page != null) {
      _saver = SessionSaver(
        session: session,
        page: page,
        source: _input,
        videoId: _positionKey ?? _input,
        title: widget.title,
        pageTitle: widget.title,
        duration: () => session.duration,
      );
    }
    setState(() {
      _session = session;
      _canResume = false;
      _cues = session.cues;
      _saved = false;
      _showSubs = true;
    });
    final item = widget.item;
    ActiveWork.begin(
      _positionKey ?? _input,
      widget.title,
      session,
      saver: _saver,
      hidden: item?.hidden ?? false,
      onSave: item == null
          ? null
          : (s) => VideoLibrary.saveCues(
              item,
              List.of(s.cues),
              language: s.language,
              covered: s.covered,
              duration: s.duration,
              complete: coversWholeVideo(
                s.covered,
                s.duration,
                reachedEnd: s.reachedEnd,
              ),
              imported: false,
            ),
    );
    session.start(_position);
  }

  void _onSession() {
    final session = _session;
    if (mounted && session?.stopped == true) {
      session!.removeListener(_onSession);
      setState(() {
        _cues = List.of(session.cues);
        _session = null;
        _saver = null;
        _canResume = true;
      });
      KeepAwake.hold(this, false);
      return;
    }
    KeepAwake.hold(this, KeepAwake.needed(session));
    if (session == null || !mounted) return;
    if (session.languageLocked && _notifiedLanguage != session.language) {
      _notifiedLanguage = session.language;
      toast(context, 'Ngôn ngữ: ${session.languageNotice}');
    }
    final item = widget.item;
    if (session.activity == SessionActivity.done &&
        !_saved &&
        item != null &&
        session.cues.isNotEmpty) {
      _saved = true;
      VideoLibrary.saveCues(
        item,
        session.cues,
        language: session.language,
        covered: session.covered,
        duration: session.duration,
        complete: coversWholeVideo(
          session.covered,
          session.duration,
          reachedEnd: session.reachedEnd,
        ),
        imported: false,
      );
    }
    setState(() {});
  }

  void _toggleSubs() {
    if ((_cues.isEmpty || _canResume) && _session == null) {
      _startSubtitles();
    } else {
      setState(() => _showSubs = !_showSubs);
    }
  }

  void _attachWork(ActiveWork work) {
    if (work.session.input != _input) return;
    _session?.removeListener(_onSession);
    setState(() {
      _session = work.session;
      _saver = work.saver;
      _cues = work.session.cues;
      _canResume = false;
      _showSubs = true;
    });
    work.session.addListener(_onSession);
    work.session.updatePosition(_position, duration: _duration);
  }

  Future<void> _stopMaking() async {
    final session = _session;
    if (session == null) return;
    session.removeListener(_onSession);
    setState(() {
      _cues = List.of(session.cues);
      _session = null;
      _saver = null;
      _canResume = true;
    });
    await ActiveWork.stop(session);
  }

  Future<void> _revise() async {
    final id = _positionKey ?? _input;
    final language =
        _session?.language ??
        (widget.item == null
            ? (await SubtitleStore.loadVideo(
                    widget.page ?? '',
                    _input,
                  ))?.language ??
                  'auto'
            : await VideoLibrary.subtitleLanguage(widget.item!));
    if (!mounted) return;
    await showSubtitleRevision(
      context,
      videoId: id,
      language: language,
      currentCues: () => List.of(_session?.cues ?? _cues),
      onApply: (next) async {
        if (!mounted) return;
        if (_session case final SubtitleSession s) {
          s.applyCues(next);
          await ActiveWork.persist(id);
        } else {
          setState(() => _cues = next);
          await _keepCues(language: language);
        }
      },
    );
  }

  Future<void> _changeLanguage() async {
    final code = await chooseVideoLanguage(
      context,
      _session?.language ?? 'auto',
    );
    if (code == null || !mounted) return;
    if (_session case final SubtitleSession session) {
      await session.selectLanguage(code);
      await ActiveWork.persist(session.videoId);
    } else {
      final page = widget.page;
      if (page != null) {
        final saved = await SubtitleStore.loadVideo(
          page,
          _input,
          duration: _duration,
          pageTitle: widget.title,
        );
        if (saved != null) await SubtitleStore.save(saved.withLanguage(code));
      } else if (widget.item case final VideoItem item) {
        await VideoLibrary.saveCues(item, _cues, language: code);
      }
    }
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(seconds: 4), () {
      if (mounted && _player.value.isPlaying) {
        setState(() => _showControls = false);
      }
    });
  }

  void _tap() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleHide();
  }

  void _seekBy(double delta) {
    final target = (_position + delta).clamp(0.0, _duration);
    _player.seekTo(Duration(milliseconds: (target * 1000).round()));
    _scheduleHide();
  }

  Future<void> _importFile() async {
    await _player.pause();
    if (!mounted) return;
    final imported = await importSubtitleFile(context);
    if (imported == null || !mounted) return;
    _session?.removeListener(_onSession);
    await ActiveWork.stop(_session);
    if (!mounted) return;
    _saver = null;
    setState(() {
      _session = null;
      _cues = imported.cues;
      _canResume = false;
      _saved = true;
      _fromFile = true;
      _showSubs = true;
    });
    await _keepCues(language: imported.language);
    if (imported.picture != null) {
      final id = widget.item == null
          ? SubtitleStore.idForVideo(widget.page!, _input)
          : 'file:${widget.item!.file.absolute.path}';
      await Bookmarks.saveThumb(
        Bookmarks.subtitlePictureKey(id),
        imported.picture!,
      );
    }
    if (mounted) {
      toast(context, 'Đã nhập ${imported.cues.length} dòng phụ đề');
    }
    await _player.play();
  }

  /// Stores the current lines with the video or the web page.
  Future<void> _keepCues({String? language}) async {
    final item = widget.item;
    final page = widget.page;
    if (item != null) {
      await VideoLibrary.saveCues(
        item,
        _cues,
        language: language ?? _session?.language ?? '',
        complete: _fromFile ? true : null,
        imported: _fromFile ? true : null,
      );
    } else if (page != null) {
      final id = SubtitleStore.idForVideo(page, _input);
      final old = await SubtitleStore.load(id);
      await SubtitleStore.save(
        SavedSubs(
          id: id,
          title: widget.title,
          page: page,
          source: _input,
          language: language ?? old?.language ?? '',
          updated: DateTime.now(),
          cues: _cues,
          covered: const [],
          duration: _duration,
          complete: true,
          imported: true,
        ),
      );
    }
  }

  Future<void> _shift(double seconds) async {
    setState(() => _cues = shiftCues(_cues, seconds));
    await _keepCues();
    if (mounted) {
      toast(
        context,
        seconds < 0
            ? 'Phụ đề sớm hơn ${-seconds} giây'
            : 'Phụ đề muộn hơn $seconds giây',
      );
    }
  }

  Future<void> _export() async {
    final item = widget.item;
    if (item == null) return;
    await _player.pause();
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ExportSheet(
        item: item,
        duration: _duration,
        cues: List.of(_cues),
        subtitlesComplete: _saved,
        initialSpeed: _speed,
      ),
    );
  }

  @override
  void dispose() {
    // Leaving the player: its work (if it goes on) becomes background.
    _session?.foreground = false;
    _hide?.cancel();
    KeepAwake.hold(this, false);
    appSettings.removeListener(_onSettings);
    ActiveWork.all.removeListener(_onWorks);
    _savePosition(now: true);
    _player.removeListener(_onTick);
    _player.dispose();
    _session?.removeListener(_onSession);
    _session?.mode = SubtitleMode.whole;
    _saver?.save();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _player.value.isInitialized;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _tap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                ),
              )
            else if (ready)
              Center(
                child: AspectRatio(
                  aspectRatio: _player.value.aspectRatio,
                  child: VideoPlayer(_player),
                ),
              )
            else
              const Center(child: CircularProgressIndicator()),
            Positioned(
              left: 0,
              right: 0,
              bottom: math.max(
                _showControls ? 120.0 : 28.0,
                MediaQuery.sizeOf(context).height * appSettings.subLift,
              ),
              child: SafeArea(
                top: false,
                child: Center(child: SubtitleText(cue: _cue)),
              ),
            ),
            if (_showControls) ...[
              Positioned(top: 0, left: 0, right: 0, child: _topBar()),
              if (ready)
                Positioned(bottom: 0, left: 0, right: 0, child: _bottomBar()),
            ],
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    final session = _session;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: Colors.white),
              onPressed: () => Navigator.pop(context),
            ),
            if (session != null) ...[
              ActivityIcon(session: session, title: widget.title),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white),
                  ),
                  if (session != null)
                    Text(
                      '${session.stage}\n${session.languageNotice}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                  if (session != null && _duration > 0)
                    Padding(
                      padding: const EdgeInsets.only(top: 3, right: 8),
                      child: CoverageBar(
                        covered: session.covered,
                        duration: _duration,
                        position: _position,
                        done: coversWholeVideo(
                          session.covered,
                          _duration,
                          reachedEnd: session.reachedEnd,
                        ),
                        height: 4,
                      ),
                    ),
                ],
              ),
            ),
            if (session != null) SessionRetryButton(session: session),
            PopupMenuButton<String>(
              tooltip: 'Phụ đề',
              icon: const Icon(Icons.subtitles_outlined, color: Colors.white),
              onSelected: (v) => switch (v) {
                'audio' => Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => RetainedAudioScreen(
                      videoId: _positionKey ?? _input,
                      includeHidden: widget.item?.hidden ?? false,
                    ),
                  ),
                ),
                'language' => _changeLanguage(),
                'revise' => _revise(),
                'stop' => _stopMaking(),
                'resume' => _startSubtitles(),
                'import' => _importFile(),
                'style' => showSubtitleStyle(context),
                'earlier' => _shift(-0.5),
                'later' => _shift(0.5),
                'details' when session != null => showSessionDetails(
                  context,
                  session,
                ),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'audio',
                  child: Text('Âm thanh lưu riêng…'),
                ),
                const PopupMenuItem(
                  value: 'language',
                  child: Text('Ngôn ngữ của video…'),
                ),
                if (_cues.isNotEmpty)
                  const PopupMenuItem(
                    value: 'revise',
                    child: Text('Yêu cầu dịch lại…'),
                  ),
                if (session != null)
                  const PopupMenuItem(value: 'stop', child: Text('Dừng dịch')),
                if (_canResume)
                  const PopupMenuItem(value: 'resume', child: Text('Làm tiếp')),
                const PopupMenuItem(
                  value: 'import',
                  child: Text('Nhập phụ đề từ file…'),
                ),
                const PopupMenuItem(
                  value: 'style',
                  child: Text('Kiểu phụ đề…'),
                ),
                if (_fromFile && _cues.isNotEmpty) ...[
                  const PopupMenuItem(
                    value: 'earlier',
                    child: Text('Phụ đề sớm hơn 0,5 giây'),
                  ),
                  const PopupMenuItem(
                    value: 'later',
                    child: Text('Phụ đề muộn hơn 0,5 giây'),
                  ),
                ],
                if (session != null)
                  const PopupMenuItem(
                    value: 'details',
                    child: Text('Chi tiết phụ đề'),
                  ),
              ],
            ),
            if (widget.item != null)
              IconButton(
                tooltip: 'Cắt / đổi tốc độ / gắn phụ đề',
                icon: const Icon(Icons.content_cut, color: Colors.white),
                onPressed: _export,
              ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final duration = _duration <= 0 ? 1.0 : _duration;
    final position = (_dragging ?? _position).clamp(0.0, duration);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    formatTime(position),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                  Expanded(
                    child: Slider(
                      value: position,
                      max: duration,
                      onChangeStart: (v) => setState(() => _dragging = v),
                      onChanged: (v) => setState(() => _dragging = v),
                      onChangeEnd: (v) {
                        _dragging = null;
                        _player.seekTo(
                          Duration(milliseconds: (v * 1000).round()),
                        );
                        _scheduleHide();
                      },
                    ),
                  ),
                  Text(
                    formatTime(duration),
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ],
              ),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  PopupMenuButton<double>(
                    tooltip: 'Tốc độ',
                    initialValue: _speed,
                    onSelected: (s) {
                      setState(() => _speed = s);
                      _player.setPlaybackSpeed(s);
                    },
                    itemBuilder: (_) => [
                      for (final s in kSpeeds)
                        PopupMenuItem(value: s, child: Text(speedLabel(s))),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        speedLabel(_speed),
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.replay_10, color: Colors.white),
                    onPressed: () => _seekBy(-10),
                  ),
                  IconButton(
                    iconSize: 44,
                    icon: Icon(
                      _player.value.isPlaying
                          ? Icons.pause_circle_filled
                          : Icons.play_circle_fill,
                      color: Colors.white,
                    ),
                    onPressed: () {
                      _player.value.isPlaying
                          ? _player.pause()
                          : _player.play();
                      _scheduleHide();
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.forward_10, color: Colors.white),
                    onPressed: () => _seekBy(10),
                  ),
                  IconButton(
                    tooltip: 'Phụ đề',
                    icon: Icon(
                      _showSubs && (_cues.isNotEmpty || _session != null)
                          ? Icons.closed_caption
                          : Icons.closed_caption_off_outlined,
                      color: Colors.white,
                    ),
                    onPressed: _toggleSubs,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
