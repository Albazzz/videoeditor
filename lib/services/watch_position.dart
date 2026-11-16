import 'package:shared_preferences/shared_preferences.dart';

/// Where the user stopped watching each video, to offer carrying on.
///
/// Keys are page ids (see SubtitleStore.idFor) for web videos and
/// `file:<name>` for library videos.
class WatchPosition {
  static const _prefix = 'pos:';

  /// Shorter videos (adverts, trailers) are not worth remembering.
  static const minDuration = 120.0;

  /// Returns the saved second to resume from, or null when there is none
  /// or the video was watched to the end.
  static Future<double?> load(String key, {double duration = 0}) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('$_prefix$key');
    if (raw == null) return null;
    final parts = raw.split('|');
    final t = double.tryParse(parts.first) ?? 0;
    final saved = parts.length > 1 ? double.tryParse(parts[1]) ?? 0 : 0.0;
    // Another video now sits on the same page (next episode).
    if (duration > 0 && saved > 0 && (saved - duration).abs() > 5) return null;
    return resumable(t, saved == 0 ? duration : saved) ? t : null;
  }

  static Future<void> save(String key, double t, double duration) async {
    if (duration < minDuration) return;
    final prefs = await SharedPreferences.getInstance();
    if (t > duration - 30) {
      // Finished: next time starts from the top.
      await prefs.remove('$_prefix$key');
    } else if (t >= 15) {
      await prefs.setString(
        '$_prefix$key',
        '${t.toStringAsFixed(1)}|${duration.toStringAsFixed(1)}',
      );
    }
  }

  /// Worth offering: past the opening and not at the credits.
  static bool resumable(double t, double duration) =>
      t >= 15 && (duration <= 0 || t < duration - 30);
}
