import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

import '../models/cue.dart';
import '../services/app_settings.dart';
import '../services/crash_trail.dart';
import '../services/subtitle_session.dart';
import '../services/subtitle_store.dart';
import '../services/video_library.dart';
import '../widgets/common.dart';
import '../widgets/subtitle_details.dart';
import 'export_sheet.dart';

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
  List<Cue> _cues = [];
  bool _showSubs = true;
  bool _showControls = true;
  bool _saved = false;
  double _speed = 1;
  String? _error;
  Timer? _hide;
  Cue? _cue;
  double? _dragging;

  String get _input => widget.item?.file.path ?? widget.url!;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
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
      if (widget.startAt > 1) {
        await _player.seekTo(
          Duration(milliseconds: (widget.startAt * 1000).round()),
        );
      }
      await _player.play();
      final item = widget.item;
      if (item != null) {
        final saved = await VideoLibrary.loadCues(item);
        if (saved.isNotEmpty && mounted) {
          setState(() {
            _cues = saved;
            _saved = true;
          });
        }
      }
      if (mounted) setState(() {});
      if (widget.autoSubtitles && _cues.isEmpty) _startSubtitles();
      _scheduleHide();
    } catch (e) {
      if (mounted) setState(() => _error = 'Không phát được video này.\n$e');
    }
  }

  double get _position => _player.value.position.inMilliseconds / 1000;
  double get _duration => _player.value.duration.inMilliseconds / 1000;

  void _onTick() {
    if (!mounted) return;
    final t = _position;
    _session?.updatePosition(t);
    final cue = _showSubs ? cueAt(_cues, t) : null;
    if (!identical(cue, _cue) || _showControls) setState(() => _cue = cue);
  }

  Future<void> _startSubtitles() async {
    if (_session != null) return;
    if (!await ensureModels(context) || !mounted) return;
    final page = widget.item == null ? widget.page : null;
    final saved = page == null
        ? null
        : await SubtitleStore.load(SubtitleStore.idFor(page));
    final reuse = saved != null && saved.language == appSettings.language;
    if (!mounted || _session != null) return;
    final session = SubtitleSession(
      input: _input,
      language: appSettings.language,
      headers: widget.headers,
      initialCues: reuse ? saved.cues : const [],
      initialCovered: reuse ? saved.covered : const [],
    )..addListener(_onSession);
    if (page != null) {
      _saver = SessionSaver(
        session: session,
        page: page,
        title: widget.title,
        duration: () => _duration,
      );
    }
    setState(() {
      _session = session;
      _cues = session.cues;
      _saved = false;
      _showSubs = true;
    });
    // A saved file should cover the whole video, so start from the top.
    session.start(widget.item != null ? 0 : _position);
  }

  void _onSession() {
    final session = _session;
    if (session == null || !mounted) return;
    final item = widget.item;
    if (session.finished &&
        !_saved &&
        item != null &&
        session.cues.isNotEmpty) {
      _saved = true;
      VideoLibrary.saveCues(item, session.cues);
    }
    setState(() {});
  }

  void _toggleSubs() {
    if (_cues.isEmpty && _session == null) {
      _startSubtitles();
    } else {
      setState(() => _showSubs = !_showSubs);
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
    _hide?.cancel();
    _player.removeListener(_onTick);
    _player.dispose();
    _session?.removeListener(_onSession);
    _saver?.close();
    _session?.dispose();
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
              bottom: _showControls ? 120 : 28,
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
                      session.error != null
                          ? session.status
                          : '${subtitleProgressLabel(covered: session.covered, duration: _duration, reachedEnd: session.finished)}'
                                ' · ${session.cues.length} dòng'
                                '${session.finished ? '' : ' · ${session.status}'}'
                                '${session.translatorNote.isEmpty ? '' : ' · ${session.translatorNote}'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
            if (session != null)
              IconButton(
                tooltip: 'Chi tiết phụ đề',
                icon: const Icon(Icons.info_outline, color: Colors.white),
                onPressed: () => showSessionDetails(context, session),
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
