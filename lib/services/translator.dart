import 'dart:io';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

/// Turns recognised speech into Vietnamese. Kept behind an interface so the
/// offline engine can be swapped for a cloud one later.
abstract class Translator {
  /// [lang] is the spoken language code ('ja', 'zh', 'yue', 'ko', 'en').
  Future<String> translate(String text, String lang);

  /// Downloads whatever [lang] needs before the first translation.
  Future<void> prepare(String lang);

  Future<void> dispose();

  static Translator create() => (Platform.isIOS || Platform.isAndroid)
      ? MlKitTranslator()
      : PassthroughTranslator();
}

/// Used where no offline engine exists (desktop development builds).
class PassthroughTranslator implements Translator {
  @override
  Future<String> translate(String text, String lang) async => text;

  @override
  Future<void> prepare(String lang) async {}

  @override
  Future<void> dispose() async {}
}

/// Google ML Kit on-device translation (offline after a ~30 MB download per
/// language).
class MlKitTranslator implements Translator {
  final _manager = OnDeviceTranslatorModelManager();
  final _translators = <TranslateLanguage, OnDeviceTranslator>{};
  final _prepared = <TranslateLanguage>{};

  static TranslateLanguage? _language(String lang) => switch (lang) {
    'ja' => TranslateLanguage.japanese,
    'zh' || 'yue' => TranslateLanguage.chinese,
    'ko' => TranslateLanguage.korean,
    'en' => TranslateLanguage.english,
    _ => null,
  };

  Future<void> _ensure(TranslateLanguage language) async {
    if (_prepared.contains(language)) return;
    for (final l in [language, TranslateLanguage.vietnamese]) {
      if (!await _manager.isModelDownloaded(l.bcpCode)) {
        await _manager.downloadModel(l.bcpCode, isWifiRequired: false);
      }
    }
    _prepared.add(language);
  }

  @override
  Future<void> prepare(String lang) async {
    final language = _language(lang);
    if (language != null) await _ensure(language);
  }

  @override
  Future<String> translate(String text, String lang) async {
    final language = _language(lang);
    if (language == null) return text;
    await _ensure(language);
    final translator = _translators.putIfAbsent(
      language,
      () => OnDeviceTranslator(
        sourceLanguage: language,
        targetLanguage: TranslateLanguage.vietnamese,
      ),
    );
    return translator.translateText(text);
  }

  @override
  Future<void> dispose() async {
    for (final t in _translators.values) {
      await t.close();
    }
    _translators.clear();
  }
}
