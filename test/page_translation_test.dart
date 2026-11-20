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
    PageTranslations.resetCache();
    PageTranslator.clearMemo();
  });
  tearDown(() async {
    PageTranslations.resetCache();
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
    'a page is translated once, kept, and opens translated again',
    () async {
      const page = 'https://phim.example/list?p=2#top';
      final fake = _Fake();
      final tr = PageTranslator(engine: () => fake);
      final first = await tr.translate(
        ['Hello', 'World'],
        page: page,
        title: 'Danh sách',
        htmlLang: 'en-US',
      );
      expect(first, {'Hello': 'VI:Hello', 'World': 'VI:World'});
      expect(fake.langs.single, 'en');
      // Asked again (another tab, a reload): nothing goes to the AI.
      await tr.translate(['Hello'], page: page);
      expect(fake.asked, hasLength(1));
      await PageTranslations.flush();
      expect(await PageTranslations.has('https://phim.example/list?p=2'), isTrue);
      final listed = (await PageTranslations.list()).single;
      expect(listed.title, 'Danh sách');
      expect(listed.count, 2);

      // A fresh start of the app reads it back from disk.
      PageTranslations.resetCache();
      PageTranslator.clearMemo();
      expect(await PageTranslations.load(page), {
        'Hello': 'VI:Hello',
        'World': 'VI:World',
      });
      await PageTranslations.delete(page);
      expect(await PageTranslations.has(page), isFalse);
      expect(await PageTranslations.list(), isEmpty);
    },
  );
}
