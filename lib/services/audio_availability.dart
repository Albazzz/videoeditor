import 'dart:math' as math;

/// Finalized audio present on disk, independent of recognition or translation.
/// Never fills gaps or adds overlapping downloads twice.
class AudioAvailability {
  AudioAvailability({
    List<(double, double)> ranges = const [],
    this.duration = 0,
    this.endOfAudio,
  }) : ranges = _merge(ranges);

  final List<(double, double)> ranges;
  final double duration;
  final double? endOfAudio;

  double get total => endOfAudio ?? (duration.isFinite ? duration : 0);
  double get seconds => ranges.fold(0, (sum, r) {
    final end = total > 0 ? math.min(total, r.$2) : r.$2;
    return sum + math.max(0, end - r.$1);
  });
  bool get complete =>
      total > 0 &&
      ranges.length == 1 &&
      ranges.single.$1 <= 0.001 &&
      ranges.single.$2 >= total - 0.001;
  double? get fraction => total > 0
      ? complete
            ? 1
            : (seconds / total).clamp(0, 0.9999)
      : null;
  int? get percent => fraction == null ? null : (fraction! * 100).floor();
  double get firstMissing =>
      ranges.isEmpty || ranges.first.$1 > 0.001 ? 0 : ranges.first.$2;

  AudioAvailability withDuration(double value) => AudioAvailability(
    ranges: ranges,
    duration: value,
    endOfAudio: endOfAudio,
  );

  String get label => total > 0
      ? 'Âm thanh đã lưu: $percent% · ${clock(seconds)} / ${clock(total)}'
      : 'Âm thanh đã lưu: ${clock(seconds)} · chưa rõ tổng thời lượng';

  static String clock(double seconds) {
    final value = seconds.floor();
    String two(int n) => n.toString().padLeft(2, '0');
    return value >= 3600
        ? '${value ~/ 3600}:${two(value ~/ 60 % 60)}:${two(value % 60)}'
        : '${value ~/ 60}:${two(value % 60)}';
  }

  static List<(double, double)> _merge(List<(double, double)> input) {
    final sorted =
        input
            .where(
              (r) => r.$1.isFinite && r.$2.isFinite && r.$2 > math.max(0, r.$1),
            )
            .map((r) => (math.max(0.0, r.$1), r.$2))
            .toList()
          ..sort((a, b) => a.$1.compareTo(b.$1));
    final merged = <(double, double)>[];
    for (final r in sorted) {
      if (merged.isNotEmpty && r.$1 <= merged.last.$2 + 0.001) {
        final last = merged.removeLast();
        merged.add((last.$1, math.max(last.$2, r.$2)));
      } else {
        merged.add(r);
      }
    }
    return List.unmodifiable(merged);
  }
}
