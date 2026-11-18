import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/app_log.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/keep_awake.dart';
import 'package:video/services/subtitle_revision.dart';
import 'package:video/services/translator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the log never keeps tokens, keys or cookies', () {
    final dirty = AppLog.sanitize(
      'ClientException: Connection closed, uri=https://tp4.example.cn/v/120.ts'
      '?auth_key=1794821146-065-ea5adbc2 key sk-or-v1-0123456789abcdef '
      'Bearer abc.def-123 hash=wdmn0Qnr&expires=1794907343 ok',
    );
    expect(dirty, isNot(contains('auth_key=1794')));
    expect(dirty, isNot(contains('abc.def-123')));
    expect(dirty, isNot(contains('0123456789abcdef')));
    expect(dirty, isNot(contains('wdmn0Qnr')));
    expect(dirty, contains('https://tp4.example.cn/v/120.ts?…'));
    expect(dirty, endsWith('ok'));

    // After a cookie/authorization header the rest of the line goes: its
    // value has spaces, so where it ends cannot be told safely.
    final header = AppLog.sanitize('sent cookie: session=xyz; a=b to cdn');
    expect(header, 'sent cookie: ***');
    // Ordinary text is left alone.
    expect(AppLog.sanitize('Nghe tới 12:30 · 5 câu'), 'Nghe tới 12:30 · 5 câu');
  });

  test('the screen stays on while any screen still works', () {
    final browser = Object();
    final player = Object();
    KeepAwake.hold(browser, true);
    KeepAwake.hold(player, true);
    KeepAwake.hold(player, false);
    expect(KeepAwake.isOn, isTrue, reason: 'the browser still works');
    KeepAwake.hold(browser, false);
    expect(KeepAwake.isOn, isFalse);
  });

  test(
    'retranslating failed lines sends only those, keeps partial results',
    () async {
      const cues = [
        Cue(start: 1, end: 2, text: 'Xin chào', source: '你好'),
        Cue(start: 3, end: 4, text: '谢谢', source: '谢谢'),
        Cue(start: 5, end: 6, text: 'Đi thôi', source: '走吧'),
        Cue(start: 7, end: 8, text: '禁止', source: '禁止'),
      ];
      final fake = _FakeTranslator({'谢谢': 'Cảm ơn'});
      final missing = [
        for (var i = 0; i < cues.length; i++)
          if (cues[i].text == cues[i].source) i,
      ];
      final rev = await CueRevision.generate(
        videoId: 'v',
        cues: cues,
        indices: missing,
        language: 'zh',
        translator: fake,
      );
      // Only the two untranslated lines went out; good lines were untouched.
      expect(fake.sent, ['谢谢', '禁止']);
      // The refused line does not throw the other away.
      expect(rev.skipped, 1);
      final next = rev.apply('v', cues);
      expect(next.map((c) => c.text), ['Xin chào', 'Cảm ơn', 'Đi thôi', '禁止']);
    },
  );
}

class _FakeTranslator implements Translator {
  _FakeTranslator(this.answers);
  final Map<String, String> answers;
  final sent = <String>[];

  @override
  Future<void> prepare(String lang) async {}

  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  }) async {
    sent.addAll(lines);
    return [for (final l in lines) answers[l]];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
