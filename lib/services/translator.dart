import 'dart:io';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'app_log.dart';
import 'app_settings.dart';
import 'crash_trail.dart';
import 'openrouter_translator.dart';

/// Turns recognised speech into Vietnamese. Kept behind an interface so the
/// offline engine can be swapped for a cloud one later.
abstract class Translator {
  /// [lang] is the spoken language code ('ja', 'zh', 'yue', 'ko', 'en').
  Future<String> translate(String text, String lang);

  /// Downloads whatever [lang] needs before the first translation.
  Future<void> prepare(String lang);

  Future<void> dispose();

  /// How long one line may take before it is shown untranslated.
  Duration get timeout;

  /// Translates many lines, e.g. a whole subtitle file. A null entry is a
  /// line that could not be translated.
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  });

  /// The translator chosen in Settings. [force] ignores the "translate"
  /// switch, for when the user asked for a translation there and then.
  static Translator create({bool force = false}) {
    if (!force && !appSettings.translate) return PassthroughTranslator();
    if (appSettings.useOpenRouter) {
      return OpenRouterTranslator(
        apiKey: appSettings.openRouterKey,
        model: appSettings.openRouterModel,
      );
    }
    return TranslatorPacks.supported
        ? MlKitTranslator()
        : PassthroughTranslator();
  }

  /// Whether anything can translate on this device.
  static bool get available =>
      appSettings.useOpenRouter || TranslatorPacks.supported;

  /// Short description for screens.
  static String get label => appSettings.useOpenRouter
      ? 'OpenRouter · ${appSettings.openRouterModel}'
      : 'trên máy (Google ML Kit)';
}

/// Translates [lines] one by one, a few at a time; a failed line is null.
Future<List<String?>> _oneByOne(
  Translator t,
  List<String> lines,
  String lang,
  void Function(int done)? onProgress,
) async {
  final out = List<String?>.filled(lines.length, null);
  var done = 0;
  const parallel = 4;
  for (var i = 0; i < lines.length; i += parallel) {
    final end = i + parallel < lines.length ? i + parallel : lines.length;
    await Future.wait([
      for (var j = i; j < end; j++)
        t
            .translate(lines[j], lang)
            .then((v) => out[j] = v, onError: (_) => null)
            .whenComplete(() => onProgress?.call(++done)),
    ]);
  }
  return out;
}

/// Used where no offline engine exists (desktop development builds).
class PassthroughTranslator implements Translator {
  @override
  Future<String> translate(String text, String lang) async => text;

  @override
  Future<void> prepare(String lang) async {}

  @override
  Future<void> dispose() async {}

  @override
  Duration get timeout => const Duration(seconds: 10);

  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  }) async {
    onProgress?.call(lines.length);
    return lines;
  }
}

/// Google ML Kit on-device translation (offline after a ~30 MB download per
/// language).
class MlKitTranslator implements Translator {
  final _manager = OnDeviceTranslatorModelManager();
  final _translators = <TranslateLanguage, OnDeviceTranslator>{};
  final _prepared = <TranslateLanguage>{};

  /// Any language ML Kit knows, by code; Vietnamese needs no translation.
  static TranslateLanguage? _language(String lang) {
    final code = lang == 'yue' ? 'zh' : lang;
    if (code == 'vi') return null;
    for (final l in TranslateLanguage.values) {
      if (l.bcpCode == code) return l;
    }
    return null;
  }

  Future<void> _ensure(TranslateLanguage language) async {
    if (_prepared.contains(language)) return;
    for (final l in [language, TranslateLanguage.vietnamese]) {
      final have = await CrashTrail.guard(
        'Kiểm tra bộ dịch (Google ML Kit)',
        () => _manager.isModelDownloaded(l.bcpCode),
      );
      if (!have) {
        final ok = await CrashTrail.guard(
          'Tải gói dịch ${l.bcpCode} (Google ML Kit)',
          () => _manager.downloadModel(l.bcpCode, isWifiRequired: false),
        );
        AppLog.i('dịch', 'Tải gói ${l.bcpCode}: ${ok ? 'xong' : 'thất bại'}');
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
  Duration get timeout => const Duration(seconds: 10);

  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  }) async {
    final language = _language(lang);
    if (language != null) await _ensure(language);
    return _oneByOne(this, lines, lang, onProgress);
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
