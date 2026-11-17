import 'package:flutter/foundation.dart';

import 'subtitle_session.dart';

/// The subtitles being made right now, if any, so other screens (the
/// subtitle store) can show their progress.
class ActiveWork {
  const ActiveWork({
    required this.id,
    required this.title,
    required this.session,
  });

  /// Store id of the page or library file (see SubtitleStore.idFor).
  final String id;
  final String title;
  final SubtitleSession session;

  static final current = ValueNotifier<ActiveWork?>(null);
  static final _running = <SubtitleSession, ActiveWork>{};

  static void begin(String id, String title, SubtitleSession session) {
    final work = ActiveWork(id: id, title: title, session: session);
    _running[session] = work;
    current.value = work;
  }

  /// Removes this session and shows another tab's work if any remains.
  static void end(SubtitleSession? session) {
    _running.remove(session);
    if (session != null && current.value?.session == session) {
      current.value = _running.values.lastOrNull;
    }
  }
}
