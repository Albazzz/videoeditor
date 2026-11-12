import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'crash_trail.dart';

const int kSampleRate = 16000;

class AsrConfig {
  const AsrConfig({
    required this.vadModel,
    required this.asrModel,
    required this.tokens,
    required this.language,
  });

  final String vadModel;
  final String asrModel;
  final String tokens;

  /// 'ja', 'zh', 'yue', 'ko', 'en' or 'auto'.
  final String language;
}

sealed class AsrEvent {
  const AsrEvent(this.gen);
  final int gen;
}

class AsrSegment extends AsrEvent {
  const AsrSegment(super.gen, this.start, this.end, this.text, this.lang);
  final double start;
  final double end;
  final String text;
  final String lang;
}

/// One chunk fully processed; speech is recognised up to [until] seconds.
class AsrProgress extends AsrEvent {
  const AsrProgress(super.gen, this.until, this.last);
  final double until;
  final bool last;
}

class AsrError extends AsrEvent {
  const AsrError(super.gen, this.message);
  final String message;
}

/// Runs voice-activity detection + speech recognition in a background
/// isolate so the UI and the video never stutter.
class AsrWorker {
  AsrWorker._(this._isolate, this._toWorker, this._events);

  final Isolate _isolate;
  final SendPort _toWorker;
  final StreamController<AsrEvent> _events;

  Stream<AsrEvent> get events => _events.stream;

  static Future<AsrWorker> spawn(AsrConfig config) async {
    final fromWorker = ReceivePort();
    final events = StreamController<AsrEvent>.broadcast();
    final ready = Completer<SendPort>();
    fromWorker.listen((msg) {
      final m = msg as Map;
      switch (m['type']) {
        case 'ready':
          ready.complete(m['port'] as SendPort);
        case 'fatal':
          if (!ready.isCompleted) {
            ready.completeError(StateError(m['message'] as String));
          } else {
            events.add(AsrError(-1, m['message'] as String));
          }
        case 'seg':
          events.add(
            AsrSegment(
              m['gen'] as int,
              m['start'] as double,
              m['end'] as double,
              m['text'] as String,
              m['lang'] as String,
            ),
          );
        case 'progress':
          events.add(
            AsrProgress(
              m['gen'] as int,
              m['until'] as double,
              m['last'] as bool,
            ),
          );
        case 'error':
          events.add(AsrError(m['gen'] as int, m['message'] as String));
      }
    });
    final isolate = await Isolate.spawn(_entry, [
      fromWorker.sendPort,
      config.vadModel,
      config.asrModel,
      config.tokens,
      config.language,
      CrashTrail.path,
    ]);
    try {
      final port = await ready.future;
      return AsrWorker._(isolate, port, events);
    } catch (_) {
      isolate.kill();
      fromWorker.close();
      rethrow;
    }
  }

  /// Starts a new timeline: following chunks begin at [baseSec].
  void reset(int gen, double baseSec) =>
      _toWorker.send({'type': 'reset', 'gen': gen, 'base': baseSec});

  /// Queues a 16 kHz mono 16-bit WAV chunk. The worker deletes the file.
  void feed(int gen, String wavPath, {bool last = false}) => _toWorker.send({
    'type': 'feed',
    'gen': gen,
    'path': wavPath,
    'last': last,
  });

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
    _events.close();
  }
}

/// Reads the PCM payload of a 16-bit mono WAV file as floats in [-1, 1].
Float32List readPcm16Wav(Uint8List bytes) {
  var offset = 12;
  var dataStart = -1;
  var dataLen = 0;
  final view = ByteData.sublistView(bytes);
  while (offset + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final size = view.getUint32(offset + 4, Endian.little);
    if (id == 'data') {
      dataStart = offset + 8;
      final remaining = bytes.length - dataStart;
      dataLen = (size == 0 || size > remaining) ? remaining : size;
      break;
    }
    offset += 8 + size + (size & 1);
  }
  if (dataStart < 0) return Float32List(0);
  final n = dataLen ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = view.getInt16(dataStart + i * 2, Endian.little) / 32768.0;
  }
  return out;
}

void _entry(List<Object?> args) {
  final out = args[0] as SendPort;
  final vadModel = args[1] as String;
  final asrModel = args[2] as String;
  final tokens = args[3] as String;
  final language = args[4] as String;
  final trail = args[5] as String?;
  var step = 0;
  int begin(String label) {
    final id = step++;
    CrashTrail.write(trail, '+w$id|$label');
    return id;
  }

  void end(int id) => CrashTrail.write(trail, '-w$id');

  late final sherpa.OfflineRecognizer recognizer;
  sherpa.VoiceActivityDetector newVad() => sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: vadModel,
        minSilenceDuration: 0.35,
        minSpeechDuration: 0.25,
        // Keeps each subtitle short enough to read.
        maxSpeechDuration: 8,
      ),
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );
  late sherpa.VoiceActivityDetector vad;

  final loading = begin('Nạp bộ nhận dạng giọng nói (sherpa-onnx)');
  try {
    sherpa.initBindings();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        model: sherpa.OfflineModelConfig(
          senseVoice: sherpa.OfflineSenseVoiceModelConfig(
            model: asrModel,
            language: language == 'auto' ? '' : language,
            useInverseTextNormalization: true,
          ),
          tokens: tokens,
          numThreads: 2,
          debug: false,
        ),
      ),
    );
    vad = newVad();
  } catch (e) {
    end(loading);
    out.send({'type': 'fatal', 'message': '$e'});
    return;
  }
  end(loading);

  var gen = 0;
  var base = 0.0;
  var fed = 0;
  const window = 512;
  // Samples that did not fill a whole VAD window, carried to the next chunk.
  var carry = Float32List(0);

  void drain() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      if (seg.samples.isEmpty) continue;
      final stream = recognizer.createStream();
      stream.acceptWaveform(samples: seg.samples, sampleRate: kSampleRate);
      recognizer.decode(stream);
      final result = recognizer.getResult(stream);
      stream.free();
      final text = result.text.trim();
      if (text.isEmpty) continue;
      final start = base + seg.start / kSampleRate;
      out.send({
        'type': 'seg',
        'gen': gen,
        'start': start,
        'end': start + seg.samples.length / kSampleRate,
        'text': text,
        'lang': result.lang.replaceAll(RegExp(r'[<>|]'), ''),
      });
    }
  }

  final inbox = ReceivePort();
  inbox.listen((msg) {
    final m = msg as Map;
    if (m['type'] == 'reset') {
      gen = m['gen'] as int;
      base = m['base'] as double;
      fed = 0;
      carry = Float32List(0);
      vad.free();
      vad = newVad();
      return;
    }
    final path = m['path'] as String;
    final file = File(path);
    if (m['gen'] != gen) {
      // A seek happened after this chunk was queued.
      try {
        file.deleteSync();
      } catch (_) {}
      return;
    }
    final last = m['last'] as bool;
    final working = begin('Nhận dạng giọng nói (sherpa-onnx)');
    try {
      final pcm = readPcm16Wav(file.readAsBytesSync());
      try {
        file.deleteSync();
      } catch (_) {}
      final samples = Float32List(carry.length + pcm.length)
        ..setAll(0, carry)
        ..setAll(carry.length, pcm);
      var i = 0;
      for (; i + window <= samples.length; i += window) {
        vad.acceptWaveform(Float32List.sublistView(samples, i, i + window));
        drain();
      }
      carry = Float32List.fromList(samples.sublist(i));
      fed += i;
      if (last) {
        vad.flush();
        drain();
      }
      out.send({
        'type': 'progress',
        'gen': gen,
        'until': base + fed / kSampleRate,
        'last': last,
      });
    } catch (e) {
      out.send({'type': 'error', 'gen': gen, 'message': '$e'});
    } finally {
      end(working);
    }
  });
  out.send({'type': 'ready', 'port': inbox.sendPort});
}
