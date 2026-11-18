import '../models/cue.dart';
import 'translator.dart';

class CueRevision {
  CueRevision(this.videoId, this.before, this.after);
  final String videoId;
  final List<Cue> before, after;

  List<Cue> apply(
    String targetVideoId,
    List<Cue> current, {
    bool undo = false,
  }) {
    if (targetVideoId != videoId) throw StateError('Bản dịch thuộc video khác');
    final expected = undo ? after : before;
    final replacement = undo ? before : after;
    final next = List.of(current);
    for (var k = 0; k < expected.length; k++) {
      final old = expected[k];
      final index = next.indexWhere(
        (c) =>
            c.start == old.start && c.end == old.end && c.source == old.source,
      );
      if (index < 0 || next[index].text != old.text) {
        throw StateError(
          'Phụ đề đã thay đổi. Hãy tạo lại bản dịch để không ghi đè nội dung mới.',
        );
      }
      next[index] = replacement[k];
    }
    return next;
  }

  static Future<CueRevision> generate({
    required String videoId,
    required List<Cue> cues,
    required List<int> indices,
    required String language,
    required Translator translator,
    void Function(int)? onProgress,
  }) async {
    final selected = indices.toSet().toList()..sort();
    if (selected.isEmpty ||
        selected.first < 0 ||
        selected.last >= cues.length) {
      throw ArgumentError('Chọn ít nhất một câu hợp lệ');
    }
    final before = [for (final i in selected) cues[i]];
    if (before.any((cue) => cue.source.trim().isEmpty)) {
      throw StateError(
        'Có câu chưa có lời gốc để dịch lại. Hãy chọn các câu được nhận dạng từ video.',
      );
    }
    await translator.prepare(language);
    final result = await translator.translateBatch(
      before.map((c) => c.source).toList(),
      language,
      onProgress: onProgress,
    );
    if (result.length != before.length ||
        result.any((text) => text == null || text.trim().isEmpty)) {
      throw StateError(
        'Chưa dịch được đầy đủ các câu đã chọn. Bản cũ vẫn được giữ.',
      );
    }
    return CueRevision(videoId, before, [
      for (var i = 0; i < before.length; i++)
        Cue(
          start: before[i].start,
          end: before[i].end,
          source: before[i].source,
          text: result[i]!,
        ),
    ]);
  }
}
