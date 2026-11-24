import 'dart:async';
import 'package:flutter/foundation.dart';

import 'subtitle_session.dart';
import 'subtitle_store.dart';
import 'keep_awake.dart';
import 'app_log.dart';
import 'background_subtitles.dart';
import 'bookmarks.dart';

/// The subtitles being made right now, if any, so other screens (the
/// subtitle store) can show their progress.
class ActiveWork {
  ActiveWork({
    required this.id,
    required this.title,
    required this.session,
    this.saver,
    this.onSave,
    this.hidden = false,
  });

  /// Store id of the page or library file (see SubtitleStore.idFor).
  final String id;
  final String title;
  final SubtitleSession session;
  final SessionSaver? saver;
  final Future<void> Function(SubtitleSession)? onSave;
  final bool hidden;
  bool _finishing = false;
  Future<void> _saving = Future.value();
  Timer? _saveTimer;
  int _savedRevision = -1;
  bool _savedWaitingForAudio = false;
  late final VoidCallback _listener = _changed;

  void _changed() {
    KeepAwake.hold(this, KeepAwake.needed(session));
    BackgroundSubtitles.instance.update(
      session,
      active:
          session.activity != SessionActivity.failed &&
          !session.stopped &&
          (!session.needsAudioSource || session.waitingTranslation > 0),
      fraction: session.progressFraction,
    );
    if (session.needsAudioSource && !_savedWaitingForAudio) {
      _savedWaitingForAudio = true;
      unawaited(_persist(force: true));
    }
    if (session.readyToFinish &&
        !_finishing &&
        !_stopping.containsKey(session)) {
      _finishing = true;
      unawaited(_finish());
    }
  }

  Future<void> _persist({bool force = false}) => _saving = _saving.then((
    _,
  ) async {
    if (_finishing || (!force && _savedRevision == session.cueRevision)) return;
    final revision = session.cueRevision;
    try {
      await saver?.save();
      await onSave?.call(session);
      _savedRevision = revision;
    } catch (e) {
      AppLog.e('phụ đề', 'Chưa lưu được phiên $id: $e');
    }
  });

  Future<void> _finish() async {
    _saveTimer?.cancel();
    try {
      // Yield before detaching or disposing: this can start inside notifyListeners.
      await _saving;
      if (!session.readyToFinish || _stopping.containsKey(session)) return;
      await saver?.close();
      await onSave?.call(session);
      if (!session.readyToFinish || _stopping.containsKey(session)) return;
      await session.markAudioCompleted();
      await session.closeAudio();
      if (!session.readyToFinish || _stopping.containsKey(session)) return;
      if (saver != null) await Bookmarks.moveSubtitles([id], '');
      if (session.stopped || !_running.containsKey(session)) return;
      _completedSessions[session] = true;
      BackgroundSubtitles.instance.finish(session);
      forgetStopped(id);
      end(session);
      session.dispose();
    } catch (e) {
      AppLog.e('phụ đề', 'Chưa hoàn tất lưu phiên: $e');
      if (_running.containsKey(session) && !session.stopped) {
        session.reportSaveFailure(e);
      }
    } finally {
      _finishing = false;
    }
  }

  static final current = ValueNotifier<ActiveWork?>(null);
  static final _running = <SubtitleSession, ActiveWork>{};
  static final _stopping = <SubtitleSession, Future<void>>{};
  static final _closingAudio = <String, Future<void>>{};
  static Future<void> waitForAudio(String id) async {
    for (final entry in _stopping.entries.toList()) {
      if (entry.key.videoId == id) {
        await entry.value;
        await entry.key.closeAudio();
      }
    }
    await _closingAudio[id];
  }

  static final all = ValueNotifier<List<ActiveWork>>(const []);
  static ActiveWork? find(String id) =>
      _running.values.where((work) => work.id == id).firstOrNull;

  static String _pageKey(String page) => SubtitleStore.pageKey(page);

  /// The work for this video: by its store id, or (pages give a video a new
  /// signed address on every visit) the same film by [sameFilm]: same page,
  /// same length and, when known, same page title. Never another episode
  /// of the page: its audio would be heard into this film's subtitles.
  static ActiveWork? findVideo(
    String id,
    String page,
    double duration, {
    String pageTitle = '',
  }) {
    final exact = find(id);
    if (exact != null) return exact;
    if (duration <= 0) return null;
    return _running.values.where((work) {
      final saver = work.saver;
      return saver != null &&
          sameFilm(
            page: page,
            duration: duration,
            title: pageTitle,
            otherPage: saver.page,
            otherDuration: work.session.duration,
            otherTitle: saver.pageTitle,
          );
    }).firstOrNull;
  }

  /// Running work for a page (any of its videos), for the browser's
  /// "subtitles are being made here" bar.
  static ActiveWork? onPage(String page) {
    final key = _pageKey(page);
    return _running.values
        .where((w) => w.saver != null && _pageKey(w.saver!.page) == key)
        .firstOrNull;
  }

  static bool isRunning(SubtitleSession session) =>
      _running.containsKey(session);

  static void begin(
    String id,
    String title,
    SubtitleSession session, {
    SessionSaver? saver,
    Future<void> Function(SubtitleSession)? onSave,
    bool hidden = false,
  }) {
    if (_running.containsKey(session)) return;
    if (find(id) != null) throw StateError('Video đã có phiên dịch: $id');
    session.audioTitle = title;
    session.audioPage = saver?.page ?? '';
    session.audioHidden = hidden;
    final work = ActiveWork(
      id: id,
      title: title,
      session: session,
      saver: saver,
      onSave: onSave,
      hidden: hidden,
    );
    _running[session] = work;
    BackgroundSubtitles.instance.begin(session);
    forgetStopped(id);
    session.addListener(work._listener);
    work._saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(work._persist()),
    );
    work._changed();
    all.value = List.unmodifiable(_running.values);
    current.value = work;
  }

  /// Work the user stopped, kept as cards with "Làm tiếp" until hidden.
  static final stopped = ValueNotifier<List<StoppedWork>>(const []);
  static final _stoppedSessions = Expando<bool>();
  static final _completedSessions = Expando<bool>();
  static bool wasCompleted(SubtitleSession session) =>
      _completedSessions[session] == true;

  /// The user stopped this session (screens showing it should let go).
  static bool wasStopped(SubtitleSession session) =>
      _stoppedSessions[session] == true;

  static void forgetStopped(String id) {
    stopped.value = List.unmodifiable(stopped.value.where((w) => w.id != id));
  }

  /// Screens detach without stopping. Only this explicit action disposes work.
  ///
  /// Stops at once: ffmpeg, recognisers and translation requests are
  /// cancelled first, then the lines made so far are saved (at most 3 s, so
  /// a stuck write or network never keeps the button from working).
  static Future<void> stop(SubtitleSession? session) {
    if (session == null) return Future.value();
    if (wasCompleted(session)) return Future.value();
    if (_stopping[session] case final Future<void> pending) return pending;
    final work = _running[session];
    // Already stopped elsewhere but still listed: finish the job anyway.
    if (session.stopped && work == null) return Future.value();
    final done = Completer<void>();
    _stopping[session] = done.future;
    _stoppedSessions[session] = true;
    session.requestStop();
    AppLog.i('phụ đề', 'Dừng dịch ${work?.title ?? ''}');
    unawaited(() async {
      try {
        try {
          await (() async {
            await work?.saver?.close();
            await work?.onSave?.call(session);
          })().timeout(
            const Duration(seconds: 3),
            onTimeout: () {
              AppLog.e('phụ đề', 'Lưu khi dừng quá 3 giây, dừng luôn');
            },
          );
        } catch (e) {
          AppLog.e('phụ đề', 'Lưu khi dừng: $e');
        } finally {
          if (work != null) _remember(work);
          end(session);
          session.dispose();
          // Audio writers close in the background; the stop is done.
          final closing = session.closeAudio().catchError((Object e) {
            AppLog.e('âm thanh', 'Đóng âm thanh sau khi dừng: $e');
          });
          _closingAudio[session.videoId] = closing;
          unawaited(
            closing.whenComplete(() {
              if (identical(_closingAudio[session.videoId], closing)) {
                _closingAudio.remove(session.videoId);
              }
            }),
          );
        }
        done.complete();
      } catch (e, st) {
        done.completeError(e, st);
      } finally {
        _stopping.remove(session);
      }
    }());
    return done.future;
  }

  static Future<void> persist(String id) async {
    final work = find(id);
    if (work == null) return;
    await work.saver?.save();
    await work.onSave?.call(work.session);
  }

  /// Removes this session and shows another tab's work if any remains.
  static void _remember(ActiveWork work) {
    final page = work.saver?.page ?? '';
    if (work.hidden || !page.startsWith('http')) return;
    final s = work.session;
    final percent = s.duration > 0
        ? ' · ${(coveredSeconds(s.covered) / s.duration * 100).clamp(0, 100).round()}%'
        : '';
    stopped.value = List.unmodifiable([
      StoppedWork(
        id: work.id,
        title: work.title,
        page: page,
        label: '${s.cues.length} dòng$percent',
      ),
      ...stopped.value.where((w) => w.id != work.id),
    ]);
  }

  static void end(SubtitleSession? session) {
    final work = _running.remove(session);
    if (work != null) {
      work._saveTimer?.cancel();
      work.session.removeListener(work._listener);
      KeepAwake.hold(work, false);
      if (!wasCompleted(session!)) BackgroundSubtitles.instance.cancel(session);
      all.value = List.unmodifiable(_running.values);
    }
    if (session != null && current.value?.session == session) {
      current.value = _running.values.lastOrNull;
    }
  }
}

/// A stopped piece of work, shown in the subtitle store with "Làm tiếp".
class StoppedWork {
  const StoppedWork({
    required this.id,
    required this.title,
    required this.page,
    required this.label,
  });
  final String id, title, page, label;
}
