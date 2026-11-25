import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:video/services/audio_feed.dart';

Uint8List pcmWav(double seconds) {
  final bytes = Uint8List(44 + (seconds * 16000).round() * 2);
  final data = ByteData.sublistView(bytes);
  void tag(int at, String value) =>
      bytes.setRange(at, at + value.length, value.codeUnits);
  tag(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  return bytes;
}

Future<void> writeAudioChunks(String directory, double seconds) async {
  var index = 0;
  while (seconds > .00001) {
    final length = math.min(
      seconds,
      index == 0
          ? 3.0
          : index == 1
          ? 5.0
          : 10.0,
    );
    await File('$directory/${chunkName(index++)}').writeAsBytes(pcmWav(length));
    seconds -= length;
  }
}
