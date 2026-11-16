import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'app_log.dart';
import 'translator.dart';

/// A model offered in Settings. Prices are US dollars per million tokens,
/// as listed by OpenRouter in November 2026.
class OpenRouterModel {
  const OpenRouterModel(this.id, this.name, this.note);
  final String id;
  final String name;
  final String note;
}

const kOpenRouterModels = [
  OpenRouterModel(
    'qwen/qwen3.7-flash',
    'Qwen 3.7 Flash',
    'Rẻ nhất, giỏi tiếng Trung/Nhật · ~150đ một phim',
  ),
  OpenRouterModel(
    'google/gemini-3.1-flash-lite',
    'Gemini 3.1 Flash Lite',
    'Dịch tự nhiên hơn · ~1.500đ một phim',
  ),
  OpenRouterModel(
    'deepseek/deepseek-v3.2',
    'DeepSeek V3.2',
    'Rất giỏi tiếng Trung · ~500đ một phim',
  ),
  OpenRouterModel(
    'google/gemma-4-31b-it:free',
    'Gemma 4 31B (miễn phí)',
    'Không mất tiền nhưng bị giới hạn số lần gọi mỗi ngày',
  ),
];

const kDefaultOpenRouterModel = 'qwen/qwen3.7-flash';

/// Raised for problems retrying will not fix (wrong key, no credit).
class OpenRouterError implements Exception {
  const OpenRouterError(this.message);
  final String message;
  @override
  String toString() => message;
}

const _languageNames = {
  'ja': 'Japanese',
  'zh': 'Chinese',
  'yue': 'Cantonese',
  'ko': 'Korean',
  'en': 'English',
  'th': 'Thai',
  'id': 'Indonesian',
  'ms': 'Malay',
  'tl': 'Filipino',
  'es': 'Spanish',
  'pt': 'Portuguese',
  'fr': 'French',
  'de': 'German',
  'it': 'Italian',
  'ru': 'Russian',
  'ar': 'Arabic',
  'hi': 'Hindi',
};

String _languageName(String code) =>
    _languageNames[code] ?? 'the language with code "$code"';

/// Translates subtitles with a language model on OpenRouter.
///
/// Lines are sent in batches with the lines just before them as context,
/// so pronouns and names stay consistent. Live lines are gathered for a
/// moment and sent together; a whole file goes in chunks of [chunkSize],
/// one after another, each retried on its own, so a long film does not
/// depend on one huge request.
class OpenRouterTranslator implements Translator {
  OpenRouterTranslator({
    required this.apiKey,
    required this.model,
    http.Client? client,
    this.gatherFor = const Duration(milliseconds: 1500),
    this.chunkSize = 30,
    this.retryDelay = const Duration(seconds: 2),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiKey;
  final String model;
  final Duration gatherFor;
  final int chunkSize;

  /// First wait before retrying; doubled each time.
  final Duration retryDelay;

  final http.Client _client;
  final bool _ownsClient;
  static final _endpoint = Uri.parse(
    'https://openrouter.ai/api/v1/chat/completions',
  );

  final _waiting = <_Waiting>[];
  Timer? _gather;
  bool _disposed = false;

  /// The last lines translated, as (original, Vietnamese), for context.
  final _recent = <(String, String)>[];

  /// Lines already translated ("Hả?", "Cảm ơn"): not sent again.
  final _done = <String, String>{};

  @override
  Duration get timeout => const Duration(minutes: 3);

  @override
  Future<void> prepare(String lang) async {}

  @override
  Future<String> translate(String text, String lang) {
    if (_disposed) return Future.error(StateError('Đã đóng bộ dịch'));
    final known = _done['$lang|$text'];
    if (known != null) return Future.value(known);
    final w = _Waiting(text, lang);
    _waiting.add(w);
    if (_waiting.length >= chunkSize) {
      _flush();
    } else {
      _gather ??= Timer(gatherFor, _flush);
    }
    return w.done.future;
  }

  void _flush() {
    _gather?.cancel();
    _gather = null;
    if (_waiting.isEmpty) return;
    final batch = List.of(_waiting);
    _waiting.clear();
    // Lines heard as different languages ('auto') go separately.
    final byLang = <String, List<_Waiting>>{};
    for (final w in batch) {
      byLang.putIfAbsent(w.lang, () => []).add(w);
    }
    for (final entry in byLang.entries) {
      final items = entry.value;
      translateBatch([for (final w in items) w.text], entry.key).then(
        (out) {
          for (var i = 0; i < items.length; i++) {
            final t = out[i];
            if (t == null) {
              items[i].done.completeError(
                const OpenRouterError('Model không trả câu này'),
              );
            } else {
              if (_done.length > 3000) _done.clear();
              _done['${items[i].lang}|${items[i].text}'] = t;
              items[i].done.complete(t);
            }
          }
        },
        onError: (Object e) {
          for (final w in items) {
            w.done.completeError(e);
          }
        },
      );
    }
  }

  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  }) async {
    final out = <String?>[];
    for (var i = 0; i < lines.length; i += chunkSize) {
      if (_disposed) throw StateError('Đã đóng bộ dịch');
      final end = i + chunkSize < lines.length ? i + chunkSize : lines.length;
      final chunk = lines.sublist(i, end);
      final done = await _translateChunk(chunk, lang);
      out.addAll(done);
      onProgress?.call(out.length);
    }
    return out;
  }

  /// One chunk; if the model returns the wrong number of lines, the chunk
  /// is halved until the answers line up.
  Future<List<String?>> _translateChunk(List<String> lines, String lang) async {
    final result = await _request(lines, lang);
    if (result != null) {
      for (var i = 0; i < lines.length; i++) {
        _recent.add((lines[i], result[i]));
      }
      while (_recent.length > 6) {
        _recent.removeAt(0);
      }
      return result;
    }
    if (lines.length == 1) return [null];
    final half = lines.length ~/ 2;
    return [
      ...await _translateChunk(lines.sublist(0, half), lang),
      ...await _translateChunk(lines.sublist(half), lang),
    ];
  }

  /// The prompt for [lines]; public for tests.
  List<Map<String, String>> messages(List<String> lines, String lang) {
    final from = lang == 'auto'
        ? 'whatever language each line is in'
        : _languageName(lang);
    final context = _recent.isEmpty
        ? ''
        : 'Lines just before these (for context only, do not translate '
              'them again):\n${jsonEncode([
                for (final r in _recent) {'src': r.$1, 'vi': r.$2},
              ])}\n\n';
    return [
      {
        'role': 'system',
        'content':
            'You translate film and TV subtitles into Vietnamese. '
            'Write natural, spoken Vietnamese as on a good Vietnamese '
            'fansub: short, easy to read quickly, keeping the meaning and '
            'tone. Choose pronouns (anh/em, tôi/cậu, mày/tao, ông/cháu…) '
            'that fit the speakers and keep them consistent. Keep names. '
            'The lines come from speech recognition and may contain '
            'mistakes: translate what was most likely said. Never add '
            'notes or explanations.',
      },
      {
        'role': 'user',
        'content':
            '${context}Translate these ${lines.length} subtitle lines from '
            '$from into Vietnamese.\n'
            'Answer with JSON only: {"vi": [...]} holding exactly '
            '${lines.length} strings, in the same order, one per line.\n\n'
            '${jsonEncode({'lines': lines})}',
      },
    ];
  }

  /// Sends one request, retrying network trouble and rate limits. Returns
  /// null when the answer does not have one translation per line.
  Future<List<String>?> _request(List<String> lines, String lang) async {
    const attempts = 4;
    for (var attempt = 1; ; attempt++) {
      final started = DateTime.now();
      try {
        final res = await _client
            .post(
              _endpoint,
              headers: {
                'Authorization': 'Bearer $apiKey',
                'Content-Type': 'application/json',
                'X-Title': 'Video Sub',
              },
              body: jsonEncode({
                'model': model,
                'messages': messages(lines, lang),
                'temperature': 0.3,
              }),
            )
            .timeout(const Duration(seconds: 90));
        final ms = DateTime.now().difference(started).inMilliseconds;
        final code = res.statusCode;
        if (code == 401 || code == 403) {
          throw const OpenRouterError(
            'Key OpenRouter không đúng hoặc đã bị thu hồi',
          );
        }
        if (code == 402) {
          throw const OpenRouterError(
            'Tài khoản OpenRouter hết tiền, nạp thêm hoặc chọn model miễn phí',
          );
        }
        if (code == 400 || code == 404) {
          throw OpenRouterError(
            'OpenRouter từ chối ($code): ${_errorText(res.body)}',
          );
        }
        if (code != 200) {
          throw _Retry('OpenRouter lỗi $code: ${_errorText(res.body)}');
        }
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is Map && body['error'] != null) {
          throw _Retry('OpenRouter: ${_errorText(res.body)}');
        }
        final content = '${body['choices']?[0]?['message']?['content'] ?? ''}';
        final usage = body['usage'];
        AppLog.i(
          'openrouter',
          '${lines.length} câu trong ${(ms / 1000).toStringAsFixed(1)} giây'
              '${usage is Map ? ' · ${usage['prompt_tokens']}+${usage['completion_tokens']} token' : ''}',
        );
        final parsed = parseTranslations(content, lines.length);
        if (parsed == null) {
          AppLog.e(
            'openrouter',
            'Trả sai số câu (cần ${lines.length}): '
                '${content.length > 300 ? content.substring(0, 300) : content}',
          );
        }
        return parsed;
      } on OpenRouterError catch (e) {
        AppLog.e('openrouter', e.message);
        rethrow;
      } catch (e) {
        if (attempt >= attempts || _disposed) {
          AppLog.e('openrouter', 'Bỏ sau $attempt lần: $e');
          throw OpenRouterError('Không dịch được qua OpenRouter: $e');
        }
        final wait = retryDelay * (1 << (attempt - 1));
        AppLog.i(
          'openrouter',
          'Lần $attempt lỗi ($e), thử lại sau ${wait.inSeconds} giây',
        );
        await Future<void>.delayed(wait);
      }
    }
  }

  static String _errorText(String body) {
    try {
      final j = jsonDecode(body);
      final m = j is Map ? j['error'] : null;
      if (m is Map && m['message'] != null) return '${m['message']}';
    } catch (_) {}
    return body.length > 200 ? body.substring(0, 200) : body;
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _gather?.cancel();
    for (final w in _waiting) {
      w.done.completeError(StateError('Đã đóng bộ dịch'));
    }
    _waiting.clear();
    if (_ownsClient) _client.close();
  }
}

/// Reads `{"vi": [...]}` (or a bare array) from a model's answer, which may
/// be wrapped in a code fence or chatter. Null unless there are exactly
/// [count] strings.
List<String>? parseTranslations(String content, int count) {
  Object? decoded;
  final start = content.indexOf(RegExp(r'[\[{]'));
  if (start < 0) return null;
  final open = content[start];
  final end = content.lastIndexOf(open == '{' ? '}' : ']');
  if (end <= start) return null;
  try {
    decoded = jsonDecode(content.substring(start, end + 1));
  } catch (_) {
    return null;
  }
  if (decoded is Map) {
    decoded = decoded['vi'] ?? decoded.values.whereType<List>().firstOrNull;
  }
  if (decoded is! List || decoded.length != count) return null;
  return [for (final x in decoded) '$x'.trim()];
}

class _Waiting {
  _Waiting(this.text, this.lang);
  final String text;
  final String lang;
  final done = Completer<String>();
}

class _Retry implements Exception {
  _Retry(this.message);
  final String message;
  @override
  String toString() => message;
}
