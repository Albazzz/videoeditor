import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
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
    this.imported = false,
    this.source = '',
  });

  final String id;
  final String title;

  /// Address of the page the video was on.
  final String page;

  /// Exact media source. Old page-only entries require manual selection.
  final String source;
  final String language;
  final DateTime updated;
  final List<Cue> cues;

  /// Stretches of the video that were listened to, in seconds.
  final List<(double, double)> covered;

  /// Length of the video in seconds, 0 when the page did not say.
  final double duration;

  /// The audio was listened to all the way to the end.
  final bool complete;

  /// Read from a subtitle file instead of made from the audio.
  final bool imported;

  SavedSubs withTitle(String newTitle) => SavedSubs(
    id: id,
    title: newTitle,
    page: page,
    source: source,
    language: language,
    updated: updated,
    cues: cues,
    covered: covered,
    duration: duration,
    complete: complete,
    imported: imported,
  );

  /// Lines still in the original language (translation failed or was
  /// off when they were made).
  int get untranslated =>
      cues.where((c) => c.source.isNotEmpty && c.text == c.source).length;

  SavedSubs withCues(List<Cue> newCues) => SavedSubs(
    id: id,
    title: title,
    page: page,
    source: source,
    language: language,
    updated: DateTime.now(),
    cues: newCues,
    covered: covered,
    duration: duration,
    complete: complete,
    imported: imported,
  );

  bool get canResume => !imported && (!isWholeVideo || untranslated > 0);

  SavedSubs withLanguage(String value) => SavedSubs(
    id: id,
    title: title,
    page: page,
    source: source,
    language: value,
    updated: DateTime.now(),
    cues: cues,
    covered: covered,
    duration: duration,
    complete: complete,
    imported: imported,
  );

  bool get isWholeVideo =>
      imported || coversWholeVideo(covered, duration, reachedEnd: complete);

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
    'source': source,
    'language': language,
    'updated': updated.millisecondsSinceEpoch,
    'duration': duration,
    'complete': complete,
    'imported': imported,
    'covered': [
      for (final r in covered) [_ms(r.$1), _ms(r.$2)],
    ],
    // Times to the millisecond; the original is left out when it is the
    // same as the shown line (not translated yet).
    'cues': [
      for (final c in cues)
        [_ms(c.start), _ms(c.end), c.text, if (c.source != c.text) c.source],
    ],
  };

  static double _ms(double v) => (v * 1000).round() / 1000;

  static SavedSubs fromJson(Map<String, Object?> j) {
    double d(Object? v) => (v as num).toDouble();
    return SavedSubs(
      id: j['id'] as String,
      title: (j['title'] as String?) ?? '',
      page: (j['page'] as String?) ?? '',
      source: (j['source'] as String?) ?? '',
      language: (j['language'] as String?) ?? '',
      updated: DateTime.fromMillisecondsSinceEpoch((j['updated'] as int?) ?? 0),
      duration: (j['duration'] as num?)?.toDouble() ?? 0,
      complete: j['complete'] == true,
      imported: j['imported'] == true,
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
            source: c.length > 3 ? c[3] as String : c[2] as String,
          ),
      ],
    );
  }
}

class SubtitleStore {
  /// Set in tests to avoid the platform directory lookup.
  static Directory? overrideDir;

  /// Bumped after every save or delete, for screens showing summaries.
  static final changes = ValueNotifier<int>(0);
  static Map<String, PageSubs>? _marks;
  static int _marksAt = -1;

  /// What the store holds for each web page (address without #…), for
  /// the "has subtitles" mark on saved pages. Cached until the next change.
  static Future<Map<String, PageSubs>> pageMarks() async {
    final at = changes.value;
    if (_marks case final Map<String, PageSubs> marks when _marksAt == at) {
      return marks;
    }
    final out = <String, PageSubs>{};
    for (final s in await list()) {
      if (!s.page.startsWith('http') || s.cues.isEmpty) continue;
      final key = pageKey(s.page);
      out[key] = PageSubs.of(s, out[key]);
    }
    _marksAt = at;
    return _marks = out;
  }

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

  /// Keep query parameters: they may identify different episodes. A signed
  /// URL changing is safer to select manually than to match the wrong film.
  static String idForVideo(String page, String source) =>
      idFor('${Uri.tryParse(page)?.removeFragment() ?? page}\n$source');

  static String _pageKey(String page) => pageKey(page);

  /// A page's address without the part after #.
  static String pageKey(String page) =>
      Uri.tryParse(page)?.removeFragment().toString() ?? page;

  static Future<SavedSubs?> loadVideo(
    String page,
    String source, {
    double duration = 0,
  }) async {
    final id = idForVideo(page, source);
    final saved = await load(id);
    if (saved != null && saved.source == source && saved.page == page) {
      if (duration > 0 &&
          saved.duration > 0 &&
          (saved.duration - duration).abs() > 5) {
        return null;
      }
      return saved;
    }
    // Streams usually get a new signed address on every visit (tokens,
    // expiry, IP). The same page with a film of the same length is the same
    // film: carry its subtitles over to the new address instead of starting
    // again (and leaving a duplicate in the store). Entries saved before
    // videos had their own key (no source) are matched the same way. Both
    // lengths must be known and agree: a page can hold several videos, and
    // a guess would put one film's lines on another.
    final key = _pageKey(page);
    SavedSubs? best;
    for (final s in await list()) {
      if (s.id == id || _pageKey(s.page) != key) continue;
      final sameLength =
          duration > 0 && s.duration > 0 && (s.duration - duration).abs() <= 5;
      if (!sameLength) continue;
      if (best == null || s.updated.isAfter(best.updated)) best = s;
    }
    if (best == null) return null;
    final moved = SavedSubs(
      id: id,
      title: best.title,
      page: page,
      source: source,
      language: best.language,
      updated: best.updated,
      cues: best.cues,
      covered: best.covered,
      duration: best.duration > 0 ? best.duration : duration,
      complete: best.complete,
      imported: best.imported,
    );
    await save(moved);
    await delete(best.id);
    return moved;
  }

  /// Entries are gzip-compressed JSON (a film's lines shrink to about a
  /// fifth); `.json` is the older, uncompressed form, still read.
  static const _ext = '.jsonz';

  static Future<File> _file(String id) async =>
      File(p.join((await _dir()).path, '$id$_ext'));

  static Future<File> _oldFile(String id) async =>
      File(p.join((await _dir()).path, '$id.json'));

  /// Writes to one entry go one after another, so overlapping saves
  /// (autosave, rename, edit, delete) neither share a temporary file nor
  /// land out of order.
  static final _queues = <String, Future<void>>{};

  /// Bumped when an entry is deleted; a session's autosave that started
  /// before must not bring it back.
  static final _epochs = <String, int>{};
  static int _tmpCounter = 0;

  static int epochOf(String id) => _epochs[id] ?? 0;

  static Future<T> _serial<T>(String id, Future<T> Function() body) {
    final result = (_queues[id] ?? Future<void>.value()).then((_) => body());
    final done = result.then<void>((_) {}, onError: (_) {});
    _queues[id] = done;
    done.whenComplete(() {
      if (identical(_queues[id], done)) _queues.remove(id);
    });
    return result;
  }

  /// [ifEpoch]: skip the write if the entry was deleted since (autosave).
  static Future<void> save(SavedSubs subs, {int? ifEpoch}) =>
      _serial(subs.id, () async {
        if (ifEpoch != null && ifEpoch != epochOf(subs.id)) return;
        final file = await _file(subs.id);
        final tmp = File('${file.path}.${pid}_${_tmpCounter++}.tmp');
        try {
          await tmp.writeAsBytes(
            gzip.encode(utf8.encode(jsonEncode(subs.toJson()))),
            flush: true,
          );
          await tmp.rename(file.path);
        } catch (_) {
          if (await tmp.exists()) await tmp.delete();
          rethrow;
        }
        final old = await _oldFile(subs.id);
        if (await old.exists()) await old.delete();
        changes.value++;
      });

  static Future<SavedSubs?> load(String id) async {
    try {
      final file = await _file(id);
      final String text;
      if (await file.exists()) {
        text = utf8.decode(gzip.decode(await file.readAsBytes()));
      } else {
        final old = await _oldFile(id);
        if (!await old.exists()) return null;
        text = await old.readAsString();
      }
      return SavedSubs.fromJson(jsonDecode(text) as Map<String, Object?>);
    } catch (_) {
      return null;
    }
  }

  static String? _idOf(String path) {
    final name = p.basename(path);
    for (final ext in [_ext, '.json']) {
      if (name.endsWith(ext)) {
        return name.substring(0, name.length - ext.length);
      }
    }
    return null;
  }

  /// Newest first.
  static Future<List<SavedSubs>> list() async {
    final ids = <String>{};
    await for (final e in (await _dir()).list()) {
      final id = e is File ? _idOf(e.path) : null;
      if (id != null) ids.add(id);
    }
    final out = <SavedSubs>[];
    for (final id in ids) {
      final s = await load(id);
      if (s != null) out.add(s);
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  /// Space the saved subtitles take, in bytes.
  static Future<int> storageBytes() async {
    var total = 0;
    await for (final e in (await _dir()).list()) {
      if (e is File && _idOf(e.path) != null) total += await e.length();
    }
    return total;
  }

  static Future<void> delete(String id) => _serial(id, () async {
    _epochs[id] = epochOf(id) + 1;
    for (final file in [await _file(id), await _oldFile(id)]) {
      if (await file.exists()) await file.delete();
    }
    changes.value++;
  });

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
    this.source = '',
    String? videoId,
  }) : id =
           videoId ??
           (source.isEmpty
               ? SubtitleStore.idFor(page)
               : SubtitleStore.idForVideo(page, source)) {
    if (source.isNotEmpty &&
        (source != session.input || id != session.videoId)) {
      throw ArgumentError('Phiên dịch và nơi lưu không cùng video');
    }
    _epoch = SubtitleStore.epochOf(id);
    session.addListener(_changed);
  }

  /// The store's epoch for this page when the session began: if the entry
  /// is deleted meanwhile, autosave stops rather than bring it back.
  late final int _epoch;

  /// Current length of the video, read at every save.
  final double Function()? duration;

  final SubtitleSession session;
  final String page;
  final String source;
  final String title;
  final String id;
  int _savedRevision = -1;
  bool _savedFinished = false;
  double _savedCovered = 0;
  Timer? _timer;

  void _changed() {
    final moved = coveredSeconds(session.covered) - _savedCovered > 60;
    if (session.cueRevision == _savedRevision &&
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

  Future<void> _pending = Future.value();
  Future<void> save() {
    _pending = _pending.then((_) => _save());
    return _pending;
  }

  Future<void> _save() async {
    if (session.cues.isEmpty) return;
    final previous = await SubtitleStore.load(id);
    // Snapshot after the disk lookup so a user revision accepted during that
    // lookup cannot be overwritten by an older background snapshot.
    final cues = List.of(session.cues);
    final covered = session.covered;
    final finished = session.finished;
    final reachedEnd = session.reachedEnd;
    final length = duration?.call() ?? 0;
    final language = session.language;
    _savedRevision = session.cueRevision;
    _savedFinished = finished;
    _savedCovered = coveredSeconds(covered);
    try {
      await SubtitleStore.save(
        ifEpoch: _epoch,
        SavedSubs(
          id: id,
          // A name the user gave the entry meanwhile is kept.
          title: previous?.title.isNotEmpty == true ? previous!.title : title,
          page: page,
          source: source,
          language: language,
          updated: DateTime.now(),
          cues: cues,
          covered: covered,
          duration: length > 0 ? length : (previous?.duration ?? 0),
          // "Finished" in follow mode only means nothing is left ahead of
          // the viewer, so it counts only when the whole film is covered.
          complete:
              coversWholeVideo(covered, length, reachedEnd: reachedEnd) ||
              (previous?.complete ?? false),
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

/// The subtitles kept for one page (all its videos), in short.
class PageSubs {
  const PageSubs({
    required this.lines,
    required this.whole,
    required this.progress,
    required this.canResume,
  });

  /// [s] added to what is already known for the page ([before]).
  factory PageSubs.of(SavedSubs s, PageSubs? before) {
    final p = s.progress;
    final b = before?.progress;
    return PageSubs(
      lines: s.cues.length + (before?.lines ?? 0),
      whole: s.isWholeVideo || (before?.whole ?? false),
      progress: p == null ? b : (b == null || p > b ? p : b),
      canResume: s.canResume || (before?.canResume ?? false),
    );
  }

  final int lines;
  final bool whole;
  final double? progress;
  final bool canResume;

  /// "CC · đủ", "CC · 45%" or "CC · 120 dòng".
  String get label => whole
      ? 'Có phụ đề · đủ phim'
      : progress != null
      ? 'Có phụ đề · ${(progress! * 100).round()}%'
      : 'Có phụ đề · $lines dòng';
}
