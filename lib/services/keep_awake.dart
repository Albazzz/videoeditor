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
      (session.activity == SessionActivity.working ||
          session.activity == SessionActivity.stuck) &&
      session.error == null;

  /// Screens (browser, player) that currently need the screen on. One
  /// screen finishing must not switch it off while another still works.
  static final _holders = <Object>{};

  /// Whether the screen is being kept on (for tests and the log).
  static bool get isOn => _on;

  /// [owner] needs the screen on ([on]) or no longer does.
  static void hold(Object owner, bool on) {
    if (on) {
      _holders.add(owner);
    } else {
      _holders.remove(owner);
    }
    _apply(_holders.isNotEmpty);
  }

  static void _apply(bool on) {
    if (on == _on) return;
    _on = on;
    AppLog.i('màn hình', on ? 'Giữ sáng khi làm phụ đề' : 'Thôi giữ sáng');
    WakelockPlus.toggle(enable: on).catchError((Object e) {
      AppLog.e('màn hình', 'Không giữ sáng được: $e');
    });
  }
}
