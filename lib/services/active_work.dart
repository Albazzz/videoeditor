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

  static void begin(String id, String title, SubtitleSession session) =>
      current.value = ActiveWork(id: id, title: title, session: session);

  /// Clears the record if it is still about [session].
  static void end(SubtitleSession? session) {
    if (session != null && current.value?.session == session) {
      current.value = null;
    }
  }
}
