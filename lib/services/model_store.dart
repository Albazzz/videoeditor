import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'asr_worker.dart';

class _ModelFile {
  const _ModelFile(this.name, this.url, this.bytes);
  final String name;
  final String url;
  final int bytes;
}

/// Speech models are downloaded once (about 240 MB) and then work offline.
class ModelStore {
  static const _files = [
    _ModelFile(
      'silero_vad.onnx',
      'https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx',
      643854,
    ),
    _ModelFile(
      'tokens.txt',
      'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/tokens.txt',
      315894,
    ),
    _ModelFile(
      'sense_voice.int8.onnx',
      'https://huggingface.co/csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17/resolve/main/model.int8.onnx',
      239233841,
    ),
  ];

  static int get totalBytes => _files.fold(0, (a, f) => a + f.bytes);

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'models'));
    await dir.create(recursive: true);
    return dir;
  }

  static Future<bool> isReady() async {
    final dir = await _dir();
    for (final f in _files) {
      final file = File(p.join(dir.path, f.name));
      if (!await file.exists() || await file.length() != f.bytes) return false;
    }
    return true;
  }

  static Future<AsrConfig> config(String language) async {
    final dir = await _dir();
    return AsrConfig(
      vadModel: p.join(dir.path, 'silero_vad.onnx'),
      tokens: p.join(dir.path, 'tokens.txt'),
      asrModel: p.join(dir.path, 'sense_voice.int8.onnx'),
      language: language,
    );
  }

  static Future<void>? _running;
  static final _listeners = <void Function(double)>{};

  /// Downloads whatever is missing. [onProgress] gets 0..1. Called again
  /// while a download runs (another screen), it joins that download
  /// instead of writing the same files twice.
  static Future<void> download(void Function(double) onProgress) {
    _listeners.add(onProgress);
    final running = _running ??=
        _download((v) {
          for (final l in List.of(_listeners)) {
            l(v);
          }
        }).whenComplete(() {
          _running = null;
          _listeners.clear();
        });
    return running;
  }

  static Future<void> _download(void Function(double) onProgress) async {
    final dir = await _dir();
    var doneBytes = 0;
    final client = http.Client();
    try {
      for (final f in _files) {
        final file = File(p.join(dir.path, f.name));
        if (await file.exists() && await file.length() == f.bytes) {
          doneBytes += f.bytes;
          onProgress(doneBytes / totalBytes);
          continue;
        }
        final part = File('${file.path}.part');
        final res = await client.send(http.Request('GET', Uri.parse(f.url)));
        if (res.statusCode != 200) {
          throw HttpException('Tải ${f.name} thất bại (${res.statusCode})');
        }
        final sink = part.openWrite();
        try {
          // A connection that stops sending must fail, not hang for ever.
          await for (final chunk in res.stream.timeout(
            const Duration(seconds: 30),
          )) {
            sink.add(chunk);
            doneBytes += chunk.length;
            onProgress(doneBytes / totalBytes);
          }
        } catch (_) {
          await sink.close();
          if (await part.exists()) await part.delete();
          rethrow;
        }
        await sink.close();
        if (await part.length() != f.bytes) {
          await part.delete();
          throw HttpException('Tải ${f.name} bị gián đoạn, hãy thử lại');
        }
        await part.rename(file.path);
      }
    } finally {
      client.close();
    }
  }

  static Future<void> deleteAll() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}
