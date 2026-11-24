import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/page_translation.dart';
import 'package:video/services/translator.dart';

/// Tags each line, and counts what it was asked for.
class _Fake implements Translator {
  final asked = <List<String>>[];
  final langs = <String>[];
  @override
  TranslatorStatus get status => const TranslatorStatus(TranslationState.ready);
  @override
  Future<String> translate(String text, String lang) async => 'VI:$text';
  @override
  Future<void> prepare(String lang) async {}
  @override
  Future<void> dispose() async {}
  @override
  Duration get timeout => const Duration(seconds: 5);
  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  }) async {
    asked.add(lines);
    langs.add(lang);
    return [for (final l in lines) 'VI:$l'];
  }
}

void main() {
  late Directory dir;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('page_tr');
    PageTranslations.overrideDir = dir;
  });
  tearDown(() async {
    PageTranslations.overrideDir = null;
    await dir.delete(recursive: true);
  });

  test('page languages: from the page, or guessed from the letters', () {
    expect(pageLanguage('zh-CN'), 'zh');
    expect(pageLanguage('vi'), 'auto');
    expect(pageLanguage(''), 'auto');
    expect(guessLanguage(['ひらがなと漢字']), 'ja');
    expect(guessLanguage(['中文标题']), 'zh');
    expect(guessLanguage(['한국어']), 'ko');
    expect(guessLanguage(['Hello']), 'en');
  });

  test(
    'translations stay in one tab and never create persistent data',
    () async {
      const page = 'https://phim.example/list?p=2#top';
      final fake = _Fake();
      final tr = PageTranslator(engine: () => fake);
      expect(
        await tr.translate(['Hello', 'World'], page: page, htmlLang: 'en-US'),
        {'Hello': 'VI:Hello', 'World': 'VI:World'},
      );
      expect(fake.langs.single, 'en');
      await tr.translate(['Hello'], page: page);
      expect(fake.asked, hasLength(1));
      expect(dir.listSync(), isEmpty);
      await tr.dispose();
      final next = PageTranslator(engine: () => fake);
      await next.translate(['Hello'], page: page);
      expect(fake.asked, hasLength(2));
      await next.dispose();
      expect(dir.listSync(), isEmpty);
    },
  );

  test(
    'upgrade removes all legacy page data and preserves other stores',
    () async {
      final legacy = await Directory('${dir.path}/page_tr').create();
      await File('${legacy.path}/old.json').writeAsString('{}');
      await File('${legacy.path}/old.map.gz').writeAsBytes([1, 2, 3]);
      final subs = await File('${dir.path}/subtitle.srt').writeAsString('keep');
      await PageTranslations.clearLegacy();
      await PageTranslations.clearLegacy();
      expect(await legacy.exists(), false);
      expect(await subs.readAsString(), 'keep');
    },
  );
}
