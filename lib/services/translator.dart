import 'dart:io';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'app_settings.dart';
import 'crash_trail.dart';

/// Turns recognised speech into Vietnamese. Kept behind an interface so the
/// offline engine can be swapped for a cloud one later.
abstract class Translator {
  /// [lang] is the spoken language code ('ja', 'zh', 'yue', 'ko', 'en').
  Future<String> translate(String text, String lang);

  /// Downloads whatever [lang] needs before the first translation.
  Future<void> prepare(String lang);

  Future<void> dispose();

  static Translator create() =>
      appSettings.translate && (Platform.isIOS || Platform.isAndroid)
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
      final have = await CrashTrail.guard(
        'Kiểm tra bộ dịch (Google ML Kit)',
        () => _manager.isModelDownloaded(l.bcpCode),
      );
      if (!have) {
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
    return CrashTrail.guard(
      'Dịch câu (Google ML Kit)',
      () => translator.translateText(text),
    );
  }

  @override
  Future<void> dispose() async {
    for (final t in _translators.values) {
      await t.close();
    }
    _translators.clear();
  }
}

/// The on-device translation packs, for the downloads screen.
class TranslatorPacks {
  /// Pack code -> name. Vietnamese is always needed as the target.
  static const languages = {
    'vi': 'Tiếng Việt (luôn cần)',
    'ja': 'Tiếng Nhật',
    'zh': 'Tiếng Trung',
    'ko': 'Tiếng Hàn',
    'en': 'Tiếng Anh',
  };

  static bool get supported => Platform.isIOS || Platform.isAndroid;

  /// Pack needed for a spoken language picked in Settings.
  static String codeFor(String lang) => lang == 'yue' ? 'zh' : lang;

  static final _manager = OnDeviceTranslatorModelManager();

  static Future<bool> isDownloaded(String code) => CrashTrail.guard(
    'Kiểm tra bộ dịch (Google ML Kit)',
    () => _manager.isModelDownloaded(code),
  );

  static Future<void> download(String code) async {
    final ok = await CrashTrail.guard(
      'Tải bộ dịch (Google ML Kit)',
      () => _manager.downloadModel(code, isWifiRequired: false),
    );
    if (!ok) throw StateError('Không tải được gói ${languages[code] ?? code}');
  }

  static Future<void> delete(String code) =>
      CrashTrail.guard('Xoá bộ dịch (Google ML Kit)', () async {
        await _manager.deleteModel(code);
      });
}
