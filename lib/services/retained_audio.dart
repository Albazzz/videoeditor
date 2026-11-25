import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'audio_availability.dart';

class RetainedAudio {
  RetainedAudio({
    required this.videoId,
    required this.title,
    required this.hidden,
    required this.bytes,
    required this.chunks,
    required this.completed,
    required this.updated,
    this.source = '',
    this.page = '',
    this.language = '',
    this.duration = 0,
  });
  final String videoId, title;
  final bool hidden, completed;
  final int bytes, chunks;
  final DateTime updated;
  final String source, page, language;
  final double duration;
  AudioAvailability? _availability;
  AudioAvailability get availability =>
      _availability ?? AudioAvailability(duration: duration);
}

class RetainedAudioChunk {
  const RetainedAudioChunk({
    required this.file,
    required this.start,
    required this.end,
    required this.run,
    required this.index,
  });
  final File file;
  final double start, end;
  final String run;
  final int index;
}

bool retainedChunkCovered(
  RetainedAudioChunk chunk,
  List<(double, double)> covered,
) => covered.any((r) => r.$1 <= chunk.start + 0.06 && r.$2 >= chunk.end - 0.06);

/// Disjoint groups, split only between WAV files so every worker keeps true time.
List<List<RetainedAudioChunk>> planRetainedAudio(
  List<RetainedAudioChunk> chunks,
  List<(double, double)> covered,
  List<(double, double)> reserved,
  int slots,
) {
  final plans = <List<RetainedAudioChunk>>[];
  final occupied = List<(double, double)>.of(reserved);
  bool available(RetainedAudioChunk c) =>
      !retainedChunkCovered(c, covered) &&
      !occupied.any((r) => c.start < r.$2 - 0.06 && c.end > r.$1 + 0.06);
  final sorted = List.of(chunks)
    ..sort((a, b) {
      final byStart = a.start.compareTo(b.start);
      return byStart != 0 ? byStart : b.end.compareTo(a.end);
    });
  while (plans.length < slots) {
    final first = sorted.where(available).firstOrNull;
    if (first == null) break;
    final group = <RetainedAudioChunk>[first];
    while (true) {
      final last = group.last;
      final next = sorted
          .where(
            (c) =>
                c.run == last.run &&
                c.index == last.index + 1 &&
                (c.start - last.end).abs() < 0.001 &&
                available(c),
          )
          .firstOrNull;
      if (next == null) break;
      group.add(next);
    }
    plans.add(group);
    occupied.add((group.first.start, group.last.end));
  }
  if (plans.length == 1 && slots > 1 && plans.single.length > 1) {
    final group = plans.removeLast();
    final mid = group.length ~/ 2;
    plans.addAll([group.sublist(0, mid), group.sublist(mid)]);
  }
  return plans;
}

/// Pins originals against deletion until recognition has closed its readers.
class RetainedAudioLease {
  RetainedAudioLease._(this._store, this._path, this.chunks, this.endOfAudio);
  final RetainedAudioStore _store;
  final String _path;
  final List<RetainedAudioChunk> chunks;
  final double? endOfAudio;
  AudioAvailability availability({double duration = 0}) => AudioAvailability(
    ranges: [for (final c in chunks) (c.start, c.end)],
    duration: duration,
    endOfAudio: endOfAudio,
  );
  bool _closed = false;

  Future<void> markCompleted() => _store._markCompleted(_path);
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    RetainedAudioStore._release(_path);
  }
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

  static void _release(String path) {
    final count = (_active[path] ?? 1) - 1;
    if (count <= 0) {
      _active.remove(path);
    } else {
      _active[path] = count;
    }
  }

  Future<AudioAvailability> availability(
    String videoId, {
    double duration = 0,
    bool includeHidden = false,
  }) async {
    final lease = await acquire(videoId, includeHidden: includeHidden);
    try {
      return lease?.availability(duration: duration) ??
          AudioAvailability(duration: duration);
    } finally {
      await lease?.close();
    }
  }

  /// Reads only this video's finalized, supported PCM chunks, including old runs.
  Future<RetainedAudioLease?> acquire(
    String videoId, {
    bool includeHidden = false,
  }) async {
    final video = await _videoDirectory(videoId);
    return _serial(video.path, () async {
      if (await FileSystemEntity.type(video.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return null;
      }
      _active.update(video.path, (n) => n + 1, ifAbsent: () => 1);
      try {
        final chunks = <RetainedAudioChunk>[];
        double? endOfAudio;
        await for (final session in video.list(followLinks: false)) {
          if (session is! Directory) continue;
          Map info;
          try {
            info =
                jsonDecode(
                      await File(
                        p.join(session.path, 'audio.json'),
                      ).readAsString(),
                    )
                    as Map;
          } catch (_) {
            continue;
          }
          if (info['videoId'] != videoId) continue;
          if (info['hidden'] == true && !includeHidden) {
            _release(video.path);
            return null;
          }
          await for (final run in session.list(followLinks: false)) {
            if (run is! Directory) continue;
            double base;
            try {
              final timeline =
                  jsonDecode(
                        await File(
                          p.join(run.path, 'timeline.json'),
                        ).readAsString(),
                      )
                      as Map;
              base = (timeline['base'] as num).toDouble();
              if (!base.isFinite || base < 0) continue;
              final eof = timeline['audioEnd'];
              if (eof is num &&
                  eof.isFinite &&
                  eof >= base &&
                  (endOfAudio == null || eof > endOfAudio)) {
                endOfAudio = eof.toDouble();
              }
            } catch (_) {
              continue;
            }
            final files = <int, File>{};
            await for (final file in run.list(followLinks: false)) {
              final match = RegExp(
                r'^c_(\d+)\.wav$',
              ).firstMatch(p.basename(file.path));
              if (file is File && match != null) {
                files[int.parse(match[1]!)] = file;
              }
            }
            var previous = -2, offset = 0.0;
            for (final index in files.keys.toList()..sort()) {
              if (index != previous + 1) {
                offset = index == 0
                    ? 0
                    : index == 1
                    ? 3
                    : 8 + (index - 2) * 10.0;
              }
              final seconds = await _wavSeconds(files[index]!);
              if (seconds == null) {
                previous = -2;
                continue;
              }
              chunks.add(
                RetainedAudioChunk(
                  file: files[index]!,
                  start: base + offset,
                  end: base + offset + seconds,
                  run: run.path,
                  index: index,
                ),
              );
              offset += seconds;
              previous = index;
            }
          }
        }
        return RetainedAudioLease._(
          this,
          video.path,
          List.unmodifiable(chunks),
          endOfAudio,
        );
      } catch (_) {
        _release(video.path);
        rethrow;
      }
    });
  }

  static Future<double?> _wavSeconds(File file) async {
    RandomAccessFile? reader;
    try {
      reader = await file.open();
      final length = await reader.length();
      // A single small read usually includes fmt, LIST and data. Revalidate
      // every time: a writer can rewrite the WAV header without changing size
      // or the filesystem's coarse modification timestamp.
      final header = await reader.read(512);
      Future<Uint8List> readAt(int offset, int count) async {
        if (offset + count <= header.length) {
          return Uint8List.sublistView(header, offset, offset + count);
        }
        await reader!.setPosition(offset);
        return reader.read(count);
      }

      if (header.length < 12 ||
          ascii.decode(header.sublist(0, 4)) != 'RIFF' ||
          ascii.decode(header.sublist(8, 12)) != 'WAVE') {
        return null;
      }
      var offset = 12, formatOk = false;
      for (var i = 0; i < 128 && offset + 8 <= length; i++) {
        final bytes = await readAt(offset, 8);
        if (bytes.length != 8) return null;
        final id = ascii.decode(bytes.sublist(0, 4));
        final size = ByteData.sublistView(bytes).getUint32(4, Endian.little);
        if (offset + 8 + size > length) return null;
        if (id == 'fmt ') {
          if (size < 16) return null;
          final fmt = ByteData.sublistView(await readAt(offset + 8, 16));
          formatOk =
              fmt.getUint16(0, Endian.little) == 1 &&
              fmt.getUint16(2, Endian.little) == 1 &&
              fmt.getUint32(4, Endian.little) == 16000 &&
              fmt.getUint16(14, Endian.little) == 16;
        }
        if (id == 'data') {
          return formatOk && size > 0 && size.isEven ? size / 32000 : null;
        }
        offset += 8 + size + (size & 1);
      }
    } catch (_) {
      return null;
    } finally {
      await reader?.close();
    }
    return null;
  }

  Future<void> _markCompleted(String path) => _serial(path, () async {
    await for (final session in Directory(path).list(followLinks: false)) {
      if (session is! Directory) continue;
      final file = File(p.join(session.path, 'audio.json'));
      Map info;
      try {
        info = jsonDecode(await file.readAsString()) as Map;
      } catch (_) {
        continue;
      }
      if (info['videoId'] is! String ||
          _key(info['videoId']) != p.basename(path)) {
        continue;
      }
      info['completed'] = true;
      info['updated'] = DateTime.now().millisecondsSinceEpoch;
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(info), flush: true);
      await temp.rename(file.path);
    }
    changes.value++;
  });

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
    String source = '',
    String page = '',
    String language = '',
    double duration = 0,
  }) async {
    final video = await _videoDirectory(videoId);
    return _serial(video.path, () async {
      await video.create(recursive: true);
      final directory = await video.createTemp('session_');
      final archive = AudioArchive._(
        video,
        directory,
        videoId,
        title,
        hidden,
        source,
        page,
        language,
        duration,
      );
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
          source: newer ? '${info['source'] ?? ''}' : previous.source,
          page: newer ? '${info['page'] ?? ''}' : previous.page,
          language: newer ? '${info['language'] ?? ''}' : previous.language,
          duration: newer
              ? (info['duration'] as num?)?.toDouble() ?? 0
              : previous.duration,
        );
      }
    }
    final visible = summaries.values
        .where((s) => includeHidden || !s.hidden)
        .toList();
    for (final audio in visible) {
      audio._availability = await availability(
        audio.videoId,
        duration: audio.duration,
        includeHidden: includeHidden,
      );
    }
    return visible..sort((a, b) => b.updated.compareTo(a.updated));
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
    this.source,
    this.page,
    this.language,
    this.duration,
  );
  final Directory _video, directory;
  final String videoId, title;
  final bool hidden;
  final String source, page, language;
  final double duration;
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

  /// Record a real extraction EOF; stopped or failed extraction never calls this.
  Future<void> recordRunEnd(
    int generation,
    double base, {
    required double videoDuration,
  }) {
    if (_closed) return _writes;
    final next = _writes.then((_) async {
      final run = Directory(p.join(directory.path, 'g$generation'));
      final files = <int, File>{};
      await for (final file in run.list(followLinks: false)) {
        final match = RegExp(
          r'^c_(\d+)\.wav$',
        ).firstMatch(p.basename(file.path));
        if (file is File && match != null) files[int.parse(match[1]!)] = file;
      }
      var end = base;
      for (var i = 0; i < files.length; i++) {
        final file = files[i];
        if (file == null) return;
        final seconds = await RetainedAudioStore._wavSeconds(file);
        if (seconds == null) return;
        end += seconds;
      }
      if (end <= base || videoDuration > 0 && end < videoDuration - 15) return;
      final timeline = File(p.join(run.path, 'timeline.json'));
      final temp = File('${timeline.path}.tmp');
      await temp.writeAsString(
        jsonEncode({'base': base, 'audioEnd': end}),
        flush: true,
      );
      await temp.rename(timeline.path);
    });
    _writes = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<void> update({bool completed = false}) {
    if (_closed) return _writes;
    _completed = _completed || completed;
    final info = jsonEncode({
      'videoId': videoId,
      'title': title,
      'hidden': hidden,
      'completed': _completed,
      if (source.isNotEmpty) 'source': source,
      if (page.isNotEmpty) 'page': page,
      if (language.isNotEmpty) 'language': language,
      if (duration > 0) 'duration': duration,
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
    RetainedAudioStore._release(_video.path);
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
