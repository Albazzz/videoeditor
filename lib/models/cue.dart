/// One subtitle line. Times are seconds on the original video timeline.
class Cue {
  const Cue({
    required this.start,
    required this.end,
    required this.text,
    this.source = '',
  });

  final double start;
  final double end;

  /// Text shown to the viewer (translated when translation succeeded).
  final String text;

  /// Original recognised speech.
  final String source;
}

String _stamp(double seconds) {
  if (seconds < 0) seconds = 0;
  final ms = (seconds * 1000).round();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:'
      '${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
}

/// Writes SRT. [from]/[to] keep only the cues inside a trimmed range and
/// shift them so the range starts at zero.
String toSrt(List<Cue> cues, {double from = 0, double? to}) {
  final out = StringBuffer();
  var n = 1;
  for (final c in cues) {
    if (c.end <= from) continue;
    if (to != null && c.start >= to) continue;
    final s = (c.start < from ? from : c.start) - from;
    final e = ((to != null && c.end > to) ? to : c.end) - from;
    if (e <= s) continue;
    out
      ..writeln(n++)
      ..writeln('${_stamp(s)} --> ${_stamp(e)}')
      ..writeln(c.text.trim())
      ..writeln();
  }
  return out.toString();
}

double? _parseStamp(String s) {
  final m = RegExp(r'(\d+):(\d+):(\d+)[,.](\d+)').firstMatch(s);
  if (m == null) return null;
  return int.parse(m[1]!) * 3600 +
      int.parse(m[2]!) * 60 +
      int.parse(m[3]!) +
      int.parse(m[4]!.padRight(3, '0').substring(0, 3)) / 1000;
}

List<Cue> parseSrt(String content) {
  final cues = <Cue>[];
  final blocks = content.replaceAll('\r', '').split(RegExp(r'\n\s*\n'));
  for (final block in blocks) {
    final lines = block.split('\n').where((l) => l.trim().isNotEmpty).toList();
    final ti = lines.indexWhere((l) => l.contains('-->'));
    if (ti < 0 || ti == lines.length - 1) continue;
    final parts = lines[ti].split('-->');
    final s = _parseStamp(parts[0]);
    final e = _parseStamp(parts[1]);
    if (s == null || e == null) continue;
    cues.add(Cue(start: s, end: e, text: lines.sublist(ti + 1).join('\n')));
  }
  return cues;
}

/// Latest cue covering [t], or null. [cues] must be sorted by start.
Cue? cueAt(List<Cue> cues, double t) {
  var lo = 0, hi = cues.length - 1, found = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (cues[mid].start <= t) {
      found = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  for (var i = found; i >= 0 && i >= found - 2; i--) {
    if (t < cues[i].end) return cues[i];
  }
  return null;
}
