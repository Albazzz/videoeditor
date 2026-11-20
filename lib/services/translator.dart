import 'dart:io';
import 'dart:async';

import 'package:google_mlkit_translation/google_mlkit_translation.dart';

import 'app_log.dart';
import 'app_settings.dart';
import 'crash_trail.dart';
import 'openrouter_translator.dart';

enum TranslationState {
  ready,
  gathering,
  sending,
  cooldown,
  downloading,
  unavailable,
  disabled,
}

class TranslatorStatus {
  const TranslatorStatus(
    this.state, {
    this.queued = 0,
    this.inFlight = 0,
    this.linesInFlight = 0,
    this.done = 0,
    this.failed = 0,
    this.blocked = 0,
    this.cooldownUntil,
    this.note = '',
  });
  final TranslationState state;
  final int queued, inFlight, linesInFlight, done, failed, blocked;
  final DateTime? cooldownUntil;
  final String note;

  String get description {
    final seconds =
        ((cooldownUntil?.difference(DateTime.now()).inMilliseconds ?? 0) / 1000)
            .ceil()
            .clamp(0, 86400);
    return switch (state) {
      TranslationState.gathering => 'Đang gom $queued câu',
      TranslationState.sending =>
        'Đang dịch $linesInFlight câu ($inFlight lượt gửi)',
      TranslationState.cooldown =>
        'Chờ $note $seconds giây do giới hạn tần suất',
      TranslationState.downloading => 'Đang tải gói dịch',
      TranslationState.unavailable => note,
      TranslationState.disabled => 'Tắt dịch, hiện câu gốc',
      TranslationState.ready => 'Bộ dịch sẵn sàng',
    };
  }
}

/// Turns recognised speech into Vietnamese. Kept behind an interface so the
/// offline engine can be swapped for a cloud one later.
abstract class Translator {
  TranslatorStatus get status;

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
  static Translator create({
    bool force = false,
    String videoId = '',
    String additionalInstruction = '',
    List<(String, String)> contextBefore = const [],
    bool forPage = false,
  }) {
    if (!force && !appSettings.translate) return PassthroughTranslator();
    final cloud = appSettings.aiProvider;
    if (cloud != null && appSettings.useCloud) {
      return OpenRouterTranslator(
        provider: cloud,
        apiKey: appSettings.keyFor(cloud),
        model: appSettings.modelFor(cloud),
        videoId: videoId,
        additionalInstruction: additionalInstruction,
        contextBefore: contextBefore,
        forPage: forPage,
      );
    }
    return TranslatorPacks.supported
        ? MlKitTranslator()
        : PassthroughTranslator();
  }

  /// Whether anything can translate on this device.
  static bool get available =>
      appSettings.useCloud || TranslatorPacks.supported;

  /// Short description for screens.
  static String get label => appSettings.useCloud
      ? '${appSettings.aiProvider!.name} · '
            '${appSettings.modelFor(appSettings.aiProvider!)}'
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
  TranslatorStatus get status =>
      const TranslatorStatus(TranslationState.disabled);
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
  final _queue =
      <
        ({
          String text,
          TranslateLanguage lang,
          double? start,
          Completer<String> result,
        })
      >[];
  final _running = <Future<void>>{};
  double position = 0;
  bool _closed = false;
  final _loading = <TranslateLanguage, Future<void>>{};
  int _active = 0, _done = 0, _failed = 0;
  @override
  TranslatorStatus get status => TranslatorStatus(
    _loading.isNotEmpty
        ? TranslationState.downloading
        : _active > 0
        ? TranslationState.sending
        : TranslationState.ready,
    queued: _queue.length,
    inFlight: _active,
    linesInFlight: _active,
    done: _done,
    failed: _failed,
  );
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

  Future<void> _ensure(TranslateLanguage language) =>
      _prepared.contains(language)
      ? Future.value()
      : _loading.putIfAbsent(
          language,
          () => _download(language).whenComplete(() {
            _loading.remove(language);
          }),
        );

  Future<void> _download(TranslateLanguage language) async {
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
        if (!ok) throw StateError('Không tải được gói dịch ${l.bcpCode}');
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
  Future<String> translate(String text, String lang, {double? start}) {
    if (_closed) return Future.error(const TranslationCancelled());
    final language = _language(lang);
    if (language == null) return Future.value(text);
    final result = Completer<String>();
    _queue.add((text: text, lang: language, start: start, result: result));
    _dispatch();
    return result.future;
  }

  void _dispatch() {
    while (!_closed && _running.length < 4 && _queue.isNotEmpty) {
      final near = _queue.indexWhere(
        (j) =>
            j.start != null &&
            j.start! >= position - 2 &&
            j.start! < position + 20,
      );
      final job = _queue.removeAt(near < 0 ? 0 : near);
      final work = _translateLine(job.text, job.lang).then<void>(
        job.result.complete,
        onError: (Object error) => job.result.completeError(error),
      );
      _running.add(work);
      work.whenComplete(() {
        _running.remove(work);
        _dispatch();
      });
    }
  }

  Future<String> _translateLine(String text, TranslateLanguage language) async {
    await _ensure(language);
    if (_closed) throw const TranslationCancelled();
    final translator = _translators.putIfAbsent(
      language,
      () => OnDeviceTranslator(
        sourceLanguage: language,
        targetLanguage: TranslateLanguage.vietnamese,
      ),
    );
    _active++;
    try {
      final result = await CrashTrail.guard(
        'Dịch câu (Google ML Kit)',
        () => translator.translateText(text).timeout(timeout),
      );
      _done++;
      return result;
    } catch (_) {
      _failed++;
      rethrow;
    } finally {
      _active--;
    }
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
    _closed = true;
    for (final job in _queue) {
      job.result.completeError(const TranslationCancelled());
    }
    _queue.clear();
    await Future.wait(_running.toList());
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
