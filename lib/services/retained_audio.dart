import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class RetainedAudio {
  RetainedAudio({
    required this.videoId,
    required this.title,
    required this.hidden,
    required this.bytes,
    required this.chunks,
    required this.completed,
    required this.updated,
  });
  final String videoId, title;
  final bool hidden, completed;
  final int bytes, chunks;
  final DateTime updated;
}

/// Persistent app-private audio. Neither normal temp cleanup nor subtitle
/// deletion owns these files. The only deletion entry point is confirmation UI.
class RetainedAudioStore {
  RetainedAudioStore({Future<Directory> Function()? baseDirectory})
    : _baseDirectory = baseDirectory ?? _platformDirectory;
  static final instance = RetainedAudioStore();
  static final changes = ValueNotifier<int>(0);
  final Future<Directory> Function() _baseDirectory;
  Future<Directory>? _root;
  static final _queues = <String, Future<void>>{};
  static final _active = <String, int>{};

  static Future<Directory> _platformDirectory() async {
    if (Platform.isIOS || Platform.isAndroid) {
      final path = await const MethodChannel(
        'vsub/private_audio',
      ).invokeMethod<String>('directory');
      if (path == null || path.isEmpty) {
        throw StateError('Không mở được kho âm thanh riêng');
      }
      return Directory(path);
    }
    return Directory(
      p.join((await getApplicationSupportDirectory()).path, 'retained_audio'),
    );
  }

  Future<Directory> _directory() => _root ??= () async {
    final root = await _baseDirectory();
    await root.create(recursive: true);
    return root.absolute;
  }();

  static String _key(String videoId) =>
      sha256.convert(utf8.encode(videoId)).toString();

  Future<Directory> _videoDirectory(String videoId) async =>
      Directory(p.join((await _directory()).path, _key(videoId)));

  static Future<T> _serial<T>(String path, Future<T> Function() action) {
    final future = (_queues[path] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final tail = future.then<void>((_) {}, onError: (_) {});
    _queues[path] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_queues[path], tail)) _queues.remove(path);
      }),
    );
    return future;
  }

  Future<AudioArchive> create(
    String videoId, {
    String title = '',
    bool hidden = false,
  }) async {
    final video = await _videoDirectory(videoId);
    return _serial(video.path, () async {
      await video.create(recursive: true);
      final directory = await video.createTemp('session_');
      final archive = AudioArchive._(video, directory, videoId, title, hidden);
      _active.update(video.path, (n) => n + 1, ifAbsent: () => 1);
      try {
        await archive.update();
      } catch (_) {
        archive._release();
        rethrow;
      }
      return archive;
    });
  }

  Future<List<RetainedAudio>> list({
    bool includeHidden = false,
    String? videoId,
  }) async {
    final root = await _directory();
    final summaries = <String, RetainedAudio>{};
    await for (final video in root.list(followLinks: false)) {
      if (video is! Directory ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(p.basename(video.path))) {
        continue;
      }
      await for (final session in video.list(followLinks: false)) {
        if (session is! Directory) continue;
        Map<String, dynamic> info;
        try {
          info =
              jsonDecode(
                    await File(
                      p.join(session.path, 'audio.json'),
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final id = info['videoId'] as String?;
        if (id == null ||
            _key(id) != p.basename(video.path) ||
            (videoId != null && id != videoId)) {
          continue;
        }
        final hidden = info['hidden'] == true;
        var bytes = 0, chunks = 0;
        await for (final file in session.list(
          recursive: true,
          followLinks: false,
        )) {
          if (file is File && p.extension(file.path) == '.wav') {
            try {
              bytes += await file.length();
              chunks++;
            } on FileSystemException {
              /* A writer may be closing. */
            }
          }
        }
        final updated = DateTime.fromMillisecondsSinceEpoch(
          (info['updated'] as int?) ?? 0,
        );
        final previous = summaries[id];
        final newer = previous == null || !updated.isBefore(previous.updated);
        summaries[id] = RetainedAudio(
          videoId: id,
          title: newer ? (info['title'] as String? ?? '') : previous.title,
          hidden: hidden || (previous?.hidden ?? false),
          bytes: bytes + (previous?.bytes ?? 0),
          chunks: chunks + (previous?.chunks ?? 0),
          completed: newer ? info['completed'] == true : previous.completed,
          updated: newer ? updated : previous.updated,
        );
      }
    }
    return summaries.values.where((s) => includeHidden || !s.hidden).toList()
      ..sort((a, b) => b.updated.compareTo(a.updated));
  }

  /// Call only after the viewer confirms. Active writers must close first.
  Future<void> deleteConfirmed(String videoId) async {
    final root = await _directory();
    final video = await _videoDirectory(videoId);
    if (!p.isWithin(root.path, video.path) ||
        p.basename(video.path) != _key(videoId)) {
      throw StateError('Đường dẫn âm thanh không hợp lệ');
    }
    await _serial(video.path, () async {
      if ((_active[video.path] ?? 0) > 0) {
        throw StateError('Âm thanh vẫn đang được xử lý. Hãy dừng phiên trước.');
      }
      if (await FileSystemEntity.type(video.path, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Đường dẫn âm thanh không hợp lệ');
      }
      if (await video.exists()) await video.delete(recursive: true);
      changes.value++;
    });
  }
}

class AudioArchive {
  AudioArchive._(
    this._video,
    this.directory,
    this.videoId,
    this.title,
    this.hidden,
  );
  final Directory _video, directory;
  final String videoId, title;
  final bool hidden;
  bool _closed = false, _completed = false;
  Future<void> _writes = Future.value();

  Future<Directory> createRun(int generation, double base) async {
    if (_closed) throw StateError('Phiên âm thanh đã đóng');
    final dir = await Directory(
      p.join(directory.path, 'g$generation'),
    ).create();
    await File(
      p.join(dir.path, 'timeline.json'),
    ).writeAsString(jsonEncode({'base': base}));
    return dir;
  }

  Future<void> update({bool completed = false}) {
    if (_closed) return _writes;
    _completed = _completed || completed;
    final info = jsonEncode({
      'videoId': videoId,
      'title': title,
      'hidden': hidden,
      'completed': _completed,
      'updated': DateTime.now().millisecondsSinceEpoch,
    });
    final next = _writes.then((_) async {
      final tmp = File(p.join(directory.path, 'audio.json.tmp'));
      await tmp.writeAsString(info, flush: true);
      await tmp.rename(p.join(directory.path, 'audio.json'));
      RetainedAudioStore.changes.value++;
    });
    _writes = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  void _release() {
    final count = (RetainedAudioStore._active[_video.path] ?? 1) - 1;
    if (count <= 0) {
      RetainedAudioStore._active.remove(_video.path);
    } else {
      RetainedAudioStore._active[_video.path] = count;
    }
  }

  Future<void> close() async {
    if (_closed) {
      await _writes;
      return;
    }
    _closed = true;
    await _writes;
    _release();
  }
}
