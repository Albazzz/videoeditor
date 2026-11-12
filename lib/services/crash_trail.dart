import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Records which risky native step is running, written synchronously and
/// flushed, so that after the app is killed by a native crash the next
/// launch can say which step it was in.
///
/// Lines: `+id|label` when a step starts, `-id` when it ends.
class CrashTrail {
  static String? _path;
  static int _next = 0;

  /// Trail file, handed to background isolates so they can write to it.
  static String? get path => _path;

  /// Reads what the previous run left unfinished, then starts afresh.
  static Future<CrashReport?> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'trail.log'));
      _path = file.path;
      if (!await file.exists()) return null;
      final report = parseTrail(await file.readAsString());
      await file.writeAsString('');
      return report;
    } catch (_) {
      return null;
    }
  }

  static int begin(String label) {
    final id = _next++;
    write(_path, '+m$id|$label');
    return id;
  }

  static void end(int id) => write(_path, '-m$id');

  static void write(String? path, String line) {
    if (path == null) return;
    try {
      File(
        path,
      ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }

  static Future<T> guard<T>(String label, Future<T> Function() body) async {
    final id = begin(label);
    try {
      return await body();
    } finally {
      end(id);
    }
  }
}

class CrashReport {
  const CrashReport(this.steps);

  /// Steps that started but never finished, oldest first.
  final List<String> steps;

  bool get inTranslator => steps.any((s) => s.contains('ML Kit'));
}

CrashReport? parseTrail(String text) {
  final open = <String, String>{};
  for (final line in text.split('\n')) {
    if (line.length < 2) continue;
    final body = line.substring(1);
    if (line[0] == '+') {
      final i = body.indexOf('|');
      if (i > 0) open[body.substring(0, i)] = body.substring(i + 1);
    } else if (line[0] == '-') {
      open.remove(body);
    }
  }
  return open.isEmpty ? null : CrashReport(open.values.toList());
}
