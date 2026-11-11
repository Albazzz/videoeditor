import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/cue.dart';

const _videoExt = {'.mp4', '.mov', '.m4v', '.mkv', '.webm', '.avi', '.ts'};

class VideoItem {
  VideoItem(this.file, this.hidden);
  final File file;
  final bool hidden;

  String get name => p.basename(file.path);
  File get srtFile => File('${p.withoutExtension(file.path)}.srt');
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
    final dir = await _dir(hidden);
    final target = await _freePath(dir, item.name);
    final srt = item.srtFile;
    await _move(item.file, target);
    if (await srt.exists()) {
      await _move(srt, '${p.withoutExtension(target)}.srt');
    }
  }

  static Future<void> delete(VideoItem item) async {
    if (await item.srtFile.exists()) await item.srtFile.delete();
    if (await item.file.exists()) await item.file.delete();
  }

  static Future<List<Cue>> loadCues(VideoItem item) async =>
      await item.srtFile.exists()
      ? parseSrt(await item.srtFile.readAsString())
      : <Cue>[];

  static Future<void> saveCues(VideoItem item, List<Cue> cues) =>
      item.srtFile.writeAsString(toSrt(cues));
}
