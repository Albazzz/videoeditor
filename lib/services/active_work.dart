import 'dart:async';
import 'package:flutter/foundation.dart';

import 'subtitle_session.dart';
import 'subtitle_store.dart';
import 'keep_awake.dart';
import 'app_log.dart';

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
  bool _closing = false;
  Timer? _saveTimer;
  int _savedRevision = -1;
  late final VoidCallback _listener = _changed;

  void _changed() {
    KeepAwake.hold(this, KeepAwake.needed(session));
    if (session.activity == SessionActivity.done) {
      unawaited(
        session.markAudioCompleted().catchError((Object error) {
          AppLog.e('âm thanh', 'Chưa lưu được trạng thái: $error');
        }),
      );
      unawaited(_persist());
    }
  }

  Future<void> _persist() async {
    if (_closing || _savedRevision == session.cueRevision) return;
    _closing = true;
    final revision = session.cueRevision;
    try {
      await saver?.save();
      await onSave?.call(session);
      _savedRevision = revision;
    } catch (e) {
      AppLog.e('phụ đề', 'Chưa lưu được phiên $id: $e');
    } finally {
      _closing = false;
    }
  }

  static final current = ValueNotifier<ActiveWork?>(null);
  static final _running = <SubtitleSession, ActiveWork>{};
  static final _stopping = <SubtitleSession, Future<void>>{};
  static final all = ValueNotifier<List<ActiveWork>>(const []);
  static ActiveWork? find(String id) =>
      _running.values.where((work) => work.id == id).firstOrNull;

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
    session.addListener(work._listener);
    work._saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(work._persist()),
    );
    work._changed();
    all.value = List.unmodifiable(_running.values);
    current.value = work;
  }

  /// Screens detach without stopping. Only this explicit action disposes work.
  static Future<void> stop(SubtitleSession? session) {
    if (session == null) return Future.value();
    if (_stopping[session] case final Future<void> pending) return pending;
    if (session.stopped) return Future.value();
    final done = Completer<void>();
    _stopping[session] = done.future;
    session.requestStop();
    final work = _running[session];
    unawaited(() async {
      try {
        try {
          await work?.saver?.close();
          await work?.onSave?.call(session);
        } finally {
          end(session);
          session.dispose();
          await session.closeAudio();
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
  static void end(SubtitleSession? session) {
    final work = _running.remove(session);
    if (work != null) {
      work._saveTimer?.cancel();
      work.session.removeListener(work._listener);
      KeepAwake.hold(work, false);
      all.value = List.unmodifiable(_running.values);
    }
    if (session != null && current.value?.session == session) {
      current.value = _running.values.lastOrNull;
    }
  }
}
