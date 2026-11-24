import 'dart:async';

import 'active_work.dart';
import 'retained_audio.dart';
import 'subtitle_session.dart';
import 'subtitle_store.dart';

enum SubtitleResumeResult {
  started,
  alreadyRunning,
  needsSource,
  cancelled,
  complete,
}

/// Resume locally without resolving a page, cookies, or an expired video URL.
class SubtitleResume {
  SubtitleResume({RetainedAudioStore? audio, this._createSession})
    : _audio = audio ?? RetainedAudioStore.instance;
  static final instance = SubtitleResume();
  final RetainedAudioStore _audio;
  final SubtitleSession Function(SavedSubs, RetainedAudioLease?)?
  _createSession;
  final _starting = <String, Future<SubtitleResumeResult>>{};

  Future<SubtitleResumeResult> resume(
    SavedSubs saved, {
    required Future<bool> Function() ensureRecognition,
    Future<void> Function(SubtitleSession)? onSave,
    bool hidden = false,
  }) {
    final pending = _starting[saved.id];
    if (pending != null) return pending;
    final future = _resume(
      saved,
      ensureRecognition: ensureRecognition,
      onSave: onSave,
      hidden: hidden,
    );
    _starting[saved.id] = future;
    unawaited(
      future.then<void>(
        (_) {
          _starting.remove(saved.id);
        },
        onError: (Object _) {
          _starting.remove(saved.id);
        },
      ),
    );
    return future;
  }

  Future<SubtitleResumeResult> _resume(
    SavedSubs saved, {
    required Future<bool> Function() ensureRecognition,
    Future<void> Function(SubtitleSession)? onSave,
    required bool hidden,
  }) async {
    await ActiveWork.waitForAudio(saved.id);
    if (onSave == null) saved = await SubtitleStore.load(saved.id) ?? saved;
    final running = ActiveWork.find(saved.id);
    if (running != null) {
      if (running.session.needsAudioSource &&
          running.session.waitingTranslation == 0) {
        await ActiveWork.stop(running.session);
        return SubtitleResumeResult.needsSource;
      }
      return SubtitleResumeResult.alreadyRunning;
    }
    final lease = await _audio.acquire(saved.id, includeHidden: hidden);
    var transferred = false;
    try {
      final hasChunks = planRetainedAudio(
        lease?.chunks ?? const [],
        mergeRanges(saved.covered),
        const [],
        1,
      ).isNotEmpty;
      if (!hasChunks && saved.untranslated == 0) {
        return saved.isWholeVideo
            ? SubtitleResumeResult.complete
            : SubtitleResumeResult.needsSource;
      }
      if (hasChunks && !await ensureRecognition()) {
        return SubtitleResumeResult.cancelled;
      }
      if (ActiveWork.find(saved.id) != null) {
        return SubtitleResumeResult.alreadyRunning;
      }
      final session =
          _createSession?.call(saved, lease) ??
          SubtitleSession(
            input: saved.source.isEmpty ? saved.page : saved.source,
            videoId: saved.id,
            language: saved.language,
            saved: saved,
            retainedAudio: _audio,
            retainedOnly: true,
            retainedInput: lease,
          );
      session.duration = saved.duration;
      session.reachedEnd = saved.complete;
      session.audioHidden = hidden;
      final saver = onSave == null
          ? SessionSaver(
              session: session,
              page: saved.page,
              title: saved.title,
              source: saved.source,
              videoId: saved.id,
              pageTitle: saved.pageTitle,
              duration: () => session.duration,
            )
          : null;
      ActiveWork.begin(
        saved.id,
        saved.title,
        session,
        saver: saver,
        onSave: onSave,
        hidden: hidden,
      );
      transferred = true;
      await session.start(0);
      return SubtitleResumeResult.started;
    } finally {
      if (!transferred) await lease?.close();
    }
  }
}
