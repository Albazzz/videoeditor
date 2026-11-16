import 'package:wakelock_plus/wakelock_plus.dart';

import 'app_log.dart';
import 'subtitle_session.dart';

/// Keeps the screen on while subtitles are being made, so the work goes on
/// with the film paused: iOS freezes an app once the phone locks.
class KeepAwake {
  static bool _on = false;

  /// True while [session] still has work to do.
  static bool needed(SubtitleSession? session) =>
      session != null &&
      !session.finished &&
      !session.paused &&
      session.error == null;

  static void update(SubtitleSession? session) => set(needed(session));

  static void set(bool on) {
    if (on == _on) return;
    _on = on;
    AppLog.i('màn hình', on ? 'Giữ sáng khi làm phụ đề' : 'Thôi giữ sáng');
    WakelockPlus.toggle(enable: on).catchError((Object e) {
      AppLog.e('màn hình', 'Không giữ sáng được: $e');
    });
  }
}
