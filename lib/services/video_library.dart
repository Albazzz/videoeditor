import 'dart:io';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';
import 'subtitle_store.dart';
import 'active_work.dart';

const _videoExt = {'.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi', '.ts'};

class VideoItem {
  VideoItem(this.file, this.hidden);
  final File file;
  final bool hidden;

  String get name => p.basename(file.path);
  File get srtFile => File('${p.withoutExtension(file.path)}.srt');
  File get subtitleDataFile => File('${file.path}.subs.json');
}

/// Videos live inside the app's private storage. Hidden ones sit in a
/// folder that is not exposed to the Files app.
class VideoLibrary {
  static Future<Directory> _dir(bool hidden) async {
    final base = hidden
        ? await getApplicationSupportDirectory()
        : await getApplicationDocumentsDirectory();
    final dir = Directory(p.join(base.path, hidden ? 'vault' : 'videos'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<List<VideoItem>> list({required bool hidden}) async {
    final dir = await _dir(hidden);
    final items = <VideoItem>[];
    await for (final e in dir.list()) {
      if (e is File && _videoExt.contains(p.extension(e.path).toLowerCase())) {
        items.add(VideoItem(e, hidden));
      }
    }
    items.sort(
      (a, b) =>
          b.file.statSync().modified.compareTo(a.file.statSync().modified),
    );
    return items;
  }

  static Future<String> _freePath(Directory dir, String name) async {
    var candidate = p.join(dir.path, name);
    var n = 1;
    while (await File(candidate).exists()) {
      candidate = p.join(
        dir.path,
        '${p.basenameWithoutExtension(name)} (${n++})${p.extension(name)}',
      );
    }
    return candidate;
  }

  /// Copies a picked video into the library.
  static Future<VideoItem> import(String sourcePath) async {
    final dir = await _dir(false);
    final target = await _freePath(dir, p.basename(sourcePath));
    return VideoItem(await File(sourcePath).copy(target), false);
  }

  /// Path for a new exported file next to the visible videos.
  static Future<String> newOutputPath(String baseName) async =>
      _freePath(await _dir(false), baseName);

  static Future<void> _move(File from, String to) async {
    try {
      await from.rename(to);
    } on FileSystemException {
      await from.copy(to);
      await from.delete();
    }
  }

  /// Moves a video (and its subtitles) into or out of the vault.
  static Future<void> setHidden(VideoItem item, bool hidden) async {
    await ActiveWork.stop(
      ActiveWork.find('file:${item.file.absolute.path}')?.session,
    );
    final dir = await _dir(hidden);
    final target = await _freePath(dir, item.name);
    final srt = item.srtFile;
    await _move(item.file, target);
    if (await srt.exists()) {
      await _move(srt, '${p.withoutExtension(target)}.srt');
    }
    if (await item.subtitleDataFile.exists()) {
      await _move(item.subtitleDataFile, '$target.subs.json');
    }
  }

  static Future<void> delete(VideoItem item) async {
    await ActiveWork.stop(
      ActiveWork.find('file:${item.file.absolute.path}')?.session,
    );
    if (await item.srtFile.exists()) await item.srtFile.delete();
    if (await item.subtitleDataFile.exists()) {
      await item.subtitleDataFile.delete();
    }
    if (await item.file.exists()) await item.file.delete();
  }

  static Future<Map<String, dynamic>?> _subtitleData(VideoItem item) async {
    try {
      return jsonDecode(await item.subtitleDataFile.readAsString())
          as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  static Future<String> subtitleLanguage(VideoItem item) async =>
      (await _subtitleData(item))?['language'] as String? ?? '';

  static Future<SavedSubs?> loadSubtitleState(VideoItem item) async {
    final data = await _subtitleData(item);
    if (data == null) return null;
    return SavedSubs(
      id: 'file:${item.file.absolute.path}',
      title: item.name,
      page: item.file.uri.toString(),
      source: item.file.path,
      language: data['language'] as String? ?? 'auto',
      updated: DateTime.now(),
      cues: await loadCues(item),
      covered: [
        for (final pair in data['covered'] as List? ?? const [])
          ((pair[0] as num).toDouble(), (pair[1] as num).toDouble()),
      ],
      duration: (data['duration'] as num?)?.toDouble() ?? 0,
      complete: data['complete'] as bool? ?? true,
      imported: data['imported'] == true,
    );
  }

  static Future<List<Cue>> loadCues(VideoItem item) async {
    final data = await _subtitleData(item);
    if (data?['cues'] case final List lines) {
      return [
        for (final c in lines)
          Cue(
            start: (c[0] as num).toDouble(),
            end: (c[1] as num).toDouble(),
            text: c[2] as String,
            source: c[3] as String,
          ),
      ];
    }
    return await item.srtFile.exists()
        ? parseSrt(await item.srtFile.readAsString())
        : <Cue>[];
  }

  static final _writes = <String, Future<void>>{};
  static Future<void> saveCues(
    VideoItem item,
    List<Cue> cues, {
    String language = '',
    List<(double, double)>? covered,
    double? duration,
    bool? complete,
    bool? imported,
  }) {
    final copy = List.of(cues);
    final ranges = covered == null
        ? null
        : [
            for (final pair in covered) [pair.$1, pair.$2],
          ];
    final task = (_writes[item.file.path] ?? Future<void>.value()).then((
      _,
    ) async {
      if (!await item.file.exists()) return;
      final old = await _subtitleData(item);
      final tmp = File('${item.subtitleDataFile.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'language': language.isEmpty ? (old?['language'] ?? '') : language,
          'covered': ranges ?? old?['covered'] ?? [],
          'duration': duration ?? old?['duration'] ?? 0,
          'complete': complete ?? old?['complete'] ?? true,
          'imported': imported ?? old?['imported'] ?? false,
          'cues': [
            for (final c in copy) [c.start, c.end, c.text, c.source],
          ],
        }),
        flush: true,
      );
      await tmp.rename(item.subtitleDataFile.path);
      await item.srtFile.writeAsString(toSrt(copy));
    });
    final tail = task.then<void>((_) {}, onError: (_) {});
    _writes[item.file.path] = tail;
    tail.then((_) {
      if (identical(_writes[item.file.path], tail)) {
        _writes.remove(item.file.path);
      }
    });
    return task;
  }
}
