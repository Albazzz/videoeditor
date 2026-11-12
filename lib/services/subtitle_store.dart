import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';
import 'subtitle_session.dart';

/// Joins overlapping or touching ranges and sorts them.
List<(double, double)> mergeRanges(List<(double, double)> ranges) {
  final sorted = ranges.where((r) => r.$2 > r.$1).toList()
    ..sort((a, b) => a.$1.compareTo(b.$1));
  final out = <(double, double)>[];
  for (final r in sorted) {
    if (out.isNotEmpty && r.$1 <= out.last.$2 + 1) {
      final last = out.removeLast();
      out.add((last.$1, r.$2 > last.$2 ? r.$2 : last.$2));
    } else {
      out.add(r);
    }
  }
  return out;
}

/// Seconds of video that have been listened to.
double coveredSeconds(List<(double, double)> ranges) =>
    mergeRanges(ranges).fold(0.0, (sum, r) => sum + r.$2 - r.$1);

/// True when the listened ranges span the whole video. [reachedEnd] means
/// the audio ran out, for when the length of the video is unknown.
bool coversWholeVideo(
  List<(double, double)> ranges,
  double duration, {
  bool reachedEnd = false,
}) {
  final merged = mergeRanges(ranges);
  if (merged.length != 1 || merged.first.$1 > 3) return false;
  if (duration > 0) return merged.first.$2 >= duration - 15;
  return reachedEnd;
}

/// Subtitles generated for one web video, kept so they can be read later
/// and reused the next time the same page is watched.
class SavedSubs {
  SavedSubs({
    required this.id,
    required this.title,
    required this.page,
    required this.language,
    required this.updated,
    required this.cues,
    required this.covered,
    this.duration = 0,
    this.complete = false,
  });

  final String id;
  final String title;

  /// Address of the page the video was on.
  final String page;
  final String language;
  final DateTime updated;
  final List<Cue> cues;

  /// Stretches of the video that were listened to, in seconds.
  final List<(double, double)> covered;

  /// Length of the video in seconds, 0 when the page did not say.
  final double duration;

  /// The audio was listened to all the way to the end.
  final bool complete;

  bool get isWholeVideo =>
      coversWholeVideo(covered, duration, reachedEnd: complete);

  /// Share of the video listened to, 0..1, or null when the length is
  /// unknown.
  double? get progress => isWholeVideo
      ? 1
      : duration <= 0
      ? null
      : (coveredSeconds(covered) / duration).clamp(0.0, 1.0);

  Map<String, Object?> toJson() => {
    'id': id,
    'title': title,
    'page': page,
    'language': language,
    'updated': updated.millisecondsSinceEpoch,
    'duration': duration,
    'complete': complete,
    'covered': [
      for (final r in covered) [r.$1, r.$2],
    ],
    'cues': [
      for (final c in cues) [c.start, c.end, c.text, c.source],
    ],
  };

  static SavedSubs fromJson(Map<String, Object?> j) {
    double d(Object? v) => (v as num).toDouble();
    return SavedSubs(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '',
      page: (j['page'] as String?) ?? '',
      language: (j['language'] as String?) ?? '',
      updated: DateTime.fromMillisecondsSinceEpoch((j['updated'] as int?) ?? 0),
      duration: (j['duration'] as num?)?.toDouble() ?? 0,
      complete: j['complete'] == true,
      covered: [
        for (final r in (j['covered'] as List? ?? const []))
          (d((r as List)[0]), d(r[1])),
      ],
      cues: [
        for (final c in (j['cues'] as List? ?? const []))
          Cue(
            start: d((c as List)[0]),
            end: d(c[1]),
            text: c[2] as String,
            source: c.length > 3 ? c[3] as String : '',
          ),
      ],
    );
  }
}

class SubtitleStore {
  /// Set in tests to avoid the platform directory lookup.
  static Directory? overrideDir;

  static Future<Directory> _dir() async {
    final base = overrideDir ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'subs'));
    await dir.create(recursive: true);
    return dir;
  }

  /// One entry per page: the stream address changes on every visit, the
  /// page address does not.
  static String idFor(String page) {
    final uri = Uri.tryParse(page);
    final key = uri == null ? page : uri.removeFragment().toString();
    return sha1.convert(utf8.encode(key)).toString().substring(0, 20);
  }

  static Future<File> _file(String id) async =>
      File(p.join((await _dir()).path, '$id.json'));

  static Future<void> save(SavedSubs subs) async {
    final file = await _file(subs.id);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonEncode(subs.toJson()));
    await tmp.rename(file.path);
  }

  static Future<SavedSubs?> load(String id) async {
    try {
      final file = await _file(id);
      if (!await file.exists()) return null;
      return SavedSubs.fromJson(
        jsonDecode(await file.readAsString()) as Map<String, Object?>,
      );
    } catch (_) {
      return null;
    }
  }

  /// Newest first.
  static Future<List<SavedSubs>> list() async {
    final out = <SavedSubs>[];
    await for (final e in (await _dir()).list()) {
      if (e is! File || !e.path.endsWith('.json')) continue;
      final s = await load(p.basenameWithoutExtension(e.path));
      if (s != null) out.add(s);
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  static Future<void> delete(String id) async {
    final file = await _file(id);
    if (await file.exists()) await file.delete();
  }

  /// Writes an .srt into the folder the Files app shows. Returns its name.
  static Future<String> exportSrt(String title, List<Cue> cues) async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = await Directory(p.join(docs.path, 'subs')).create();
    var name = title.replaceAll(RegExp(r'[\\/:*?"<>|\n\r]'), ' ').trim();
    if (name.isEmpty) name = 'phu-de';
    if (name.length > 60) name = name.substring(0, 60).trim();
    final file = File(p.join(dir.path, '$name.srt'));
    await file.writeAsString(toSrt(cues));
    return 'subs/$name.srt';
  }
}

/// Keeps a web session's subtitles in the store while it runs.
class SessionSaver {
  SessionSaver({
    required this.session,
    required this.page,
    required this.title,
    this.duration,
  }) : id = SubtitleStore.idFor(page) {
    session.addListener(_changed);
  }

  /// Current length of the video, read at every save.
  final double Function()? duration;

  final SubtitleSession session;
  final String page;
  final String title;
  final String id;
  int _savedCount = -1;
  bool _savedFinished = false;
  double _savedCovered = 0;
  Timer? _timer;

  void _changed() {
    final moved = coveredSeconds(session.covered) - _savedCovered > 60;
    if (session.cues.length == _savedCount &&
        session.finished == _savedFinished &&
        !moved) {
      return;
    }
    // Lines arrive in bursts; one write a few seconds later covers them.
    _timer ??= Timer(const Duration(seconds: 5), () {
      _timer = null;
      save();
    });
  }

  Future<void> save() async {
    if (session.cues.isEmpty) return;
    // Copy everything first: the session may be disposed while we wait.
    final cues = List.of(session.cues);
    final covered = session.covered;
    final finished = session.finished;
    final length = duration?.call() ?? 0;
    _savedCount = cues.length;
    _savedFinished = finished;
    _savedCovered = coveredSeconds(covered);
    final previous = await SubtitleStore.load(id);
    try {
      await SubtitleStore.save(
        SavedSubs(
          id: id,
          title: title,
          page: page,
          language: session.language,
          updated: DateTime.now(),
          cues: cues,
          covered: covered,
          duration: length > 0 ? length : (previous?.duration ?? 0),
          complete: finished || (previous?.complete ?? false),
        ),
      );
    } catch (_) {}
  }

  /// Call before the session is disposed.
  Future<void> close() {
    _timer?.cancel();
    session.removeListener(_changed);
    return save();
  }
}
