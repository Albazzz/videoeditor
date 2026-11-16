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
  const OpenRouterError(this.message, {this.account = false});
  final String message;

  /// The key or the balance is the problem: no request will work until
  /// the user fixes it.
  final bool account;
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
/// Lines go in requests of about [budget] characters (never cutting a
/// line), up to [parallel] requests at a time. Each request numbers its
/// lines and carries the lines just before it as context; a line the
/// model leaves out is asked for again on its own, instead of throwing
/// the whole request away.
class OpenRouterTranslator implements Translator {
  OpenRouterTranslator({
    required this.apiKey,
    required this.model,
    http.Client? client,
    this.gatherFor = const Duration(milliseconds: 1500),
    this.budget = 1500,
    this.maxLines = 80,
    this.parallel = 3,
    this.retryDelay = const Duration(seconds: 2),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiKey;
  final String model;
  final Duration gatherFor;

  /// Characters of original text per request: Chinese or Japanese lines
  /// are short in characters but dense, so this is about 30–80 lines.
  final int budget;
  final int maxLines;

  /// Requests in flight at once.
  final int parallel;

  /// First wait before retrying; doubled each time.
  final Duration retryDelay;

  final http.Client _client;
  final bool _ownsClient;
  static final _endpoint = Uri.parse(
    'https://openrouter.ai/api/v1/chat/completions',
  );

  final _waiting = <_Waiting>[];
  int _waitingChars = 0;
  Timer? _gather;
  bool _disposed = false;
  int _inFlight = 0;
  final _slots = <Completer<void>>[];

  /// The last lines translated live, as (original, Vietnamese).
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
    _waitingChars += text.length;
    _dispatch();
    return w.done.future;
  }

  /// Live lines in requests now running.
  int _liveRequests = 0;

  /// Sends waiting lines whenever a request slot is free. A request goes
  /// once it is full (about [budget] characters) or its oldest line has
  /// waited [gatherFor]; while all slots are busy lines pile up, so the
  /// next request takes many at once. That way translation keeps up even
  /// when speech is heard much faster than the film plays.
  void _dispatch() {
    _gather?.cancel();
    _gather = null;
    while (_waiting.isNotEmpty && _liveRequests < parallel && !_disposed) {
      final full = _waitingChars >= budget || _waiting.length >= maxLines;
      final age = DateTime.now().difference(_waiting.first.since);
      if (!full && age < gatherFor) {
        _gather = Timer(gatherFor - age, _dispatch);
        return;
      }
      final batch = <_Waiting>[];
      var chars = 0;
      while (_waiting.isNotEmpty) {
        final next = _waiting.first;
        if (batch.isNotEmpty &&
            (chars + next.text.length > budget || batch.length >= maxLines)) {
          break;
        }
        batch.add(_waiting.removeAt(0));
        chars += next.text.length;
      }
      _waitingChars -= chars;
      _sendLive(batch);
    }
  }

  void _sendLive(List<_Waiting> batch) {
    // Lines heard as different languages ('auto') go separately.
    final byLang = <String, List<_Waiting>>{};
    for (final w in batch) {
      byLang.putIfAbsent(w.lang, () => []).add(w);
    }
    for (final entry in byLang.entries) {
      final items = entry.value;
      final context = List.of(_recent);
      _liveRequests++;
      _translateChunk([for (final w in items) w.text], entry.key, context)
          .then(
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
                  _recent.add((items[i].text, t));
                  items[i].done.complete(t);
                }
              }
              while (_recent.length > 6) {
                _recent.removeAt(0);
              }
            },
            onError: (Object e) {
              for (final w in items) {
                w.done.completeError(e);
              }
            },
          )
          .whenComplete(() {
            _liveRequests--;
            _dispatch();
          });
    }
  }

  @override
  Future<List<String?>> translateBatch(
    List<String> lines,
    String lang, {
    void Function(int done)? onProgress,
  }) async {
    final out = List<String?>.filled(lines.length, null);
    final chunks = chunkByLength(lines, budget: budget, maxLines: maxLines);
    var done = 0;
    Object? failure;
    await Future.wait([
      for (final c in chunks)
        () async {
          // The original lines just before this chunk give it context;
          // their translations may not exist yet (chunks run together).
          final from = c.$1 - 6 < 0 ? 0 : c.$1 - 6;
          final context = [
            for (var i = from; i < c.$1; i++) (lines[i], out[i] ?? ''),
          ];
          try {
            final res = await _translateChunk(
              lines.sublist(c.$1, c.$2),
              lang,
              context,
            );
            out.setRange(c.$1, c.$2, res);
          } on OpenRouterError catch (e) {
            // A wrong key or no credit: no point going on.
            failure ??= e;
          }
          done += c.$2 - c.$1;
          onProgress?.call(done);
        }(),
    ]);
    final f = failure;
    if (f != null && out.every((t) => t == null)) throw f;
    return out;
  }

  /// One request; lines the model leaves out are asked for again on
  /// their own (a few at a time) so they keep their neighbours' context.
  Future<List<String?>> _translateChunk(
    List<String> lines,
    String lang,
    List<(String, String)> context,
  ) async {
    final out = await _request(lines, lang, context);
    final missing = [
      for (var i = 0; i < lines.length; i++)
        if (out[i] == null) i,
    ];
    if (missing.isEmpty || lines.length == 1) return out;
    AppLog.i('openrouter', 'Hỏi lại ${missing.length} câu bị bỏ sót');
    for (var k = 0; k < missing.length; k += 5) {
      final group = missing.sublist(
        k,
        k + 5 < missing.length ? k + 5 : missing.length,
      );
      final first = group.first;
      final near = [
        for (var i = first - 3 < 0 ? 0 : first - 3; i < first; i++)
          (lines[i], out[i] ?? ''),
      ];
      final again = await _request(
        [for (final i in group) lines[i]],
        lang,
        near.isEmpty ? context : near,
      );
      for (var j = 0; j < group.length; j++) {
        out[group[j]] = again[j];
      }
    }
    return out;
  }

  /// The prompt for [lines]; public for tests.
  List<Map<String, String>> messages(
    List<String> lines,
    String lang, [
    List<(String, String)> context = const [],
  ]) {
    final from = lang == 'auto'
        ? 'whatever language each line is in'
        : _languageName(lang);
    final before = context.isEmpty
        ? ''
        : 'Lines just before these, for context only (do not translate '
              'them):\n${jsonEncode([
                for (final r in context) {'src': r.$1, if (r.$2.isNotEmpty) 'vi': r.$2},
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
            '${before}Translate the ${lines.length} numbered subtitle lines '
            'below from $from into Vietnamese. Translate every line on its '
            'own, even very short ones; never merge or skip lines.\n'
            'Answer with JSON only, the same numbers as keys: '
            '{"1": "…", "2": "…"}\n\n'
            '${jsonEncode({
              'lines': {for (var i = 0; i < lines.length; i++) '${i + 1}': lines[i]},
            })}',
      },
    ];
  }

  /// Waits for one of the [parallel] request slots.
  Future<void> _acquire() async {
    while (_inFlight >= parallel) {
      final c = Completer<void>();
      _slots.add(c);
      await c.future;
    }
    _inFlight++;
  }

  void _release() {
    _inFlight--;
    if (_slots.isNotEmpty) _slots.removeAt(0).complete();
  }

  /// Sends one request, retrying network trouble and rate limits. Lines
  /// missing from the answer are null.
  Future<List<String?>> _request(
    List<String> lines,
    String lang,
    List<(String, String)> context,
  ) async {
    await _acquire();
    try {
      return await _send(lines, lang, context);
    } finally {
      _release();
    }
  }

  Future<List<String?>> _send(
    List<String> lines,
    String lang,
    List<(String, String)> context,
  ) async {
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
                'X-Title': 'AIcall app',
              },
              body: jsonEncode({
                'model': model,
                'messages': messages(lines, lang, context),
                'temperature': 0.3,
              }),
            )
            .timeout(const Duration(seconds: 90));
        final ms = DateTime.now().difference(started).inMilliseconds;
        final code = res.statusCode;
        if (code == 401 || code == 403) {
          throw const OpenRouterError(
            'Key OpenRouter không đúng hoặc đã bị thu hồi',
            account: true,
          );
        }
        if (code == 402) {
          throw const OpenRouterError(
            'Tài khoản OpenRouter hết tiền, nạp thêm hoặc chọn model miễn phí',
            account: true,
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
        final parsed = parseTranslations(content, lines.length);
        final got = parsed.where((t) => t != null).length;
        AppLog.i(
          'openrouter',
          '$got/${lines.length} câu (${lines.fold(0, (n, l) => n + l.length)} '
              'ký tự) trong ${(ms / 1000).toStringAsFixed(1)} giây'
              '${usage is Map ? ' · ${usage['prompt_tokens']}+${usage['completion_tokens']} token' : ''}',
        );
        if (got == 0) {
          AppLog.e(
            'openrouter',
            'Không đọc được câu trả lời: '
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

/// Splits [lines] into requests of about [budget] characters and at most
/// [maxLines] lines, as (start, end) index pairs. A line is never cut,
/// and a line longer than the budget goes alone.
List<(int, int)> chunkByLength(
  List<String> lines, {
  int budget = 1500,
  int maxLines = 80,
}) {
  final out = <(int, int)>[];
  var start = 0;
  var chars = 0;
  for (var i = 0; i < lines.length; i++) {
    final len = lines[i].length;
    if (i > start && (chars + len > budget || i - start >= maxLines)) {
      out.add((start, i));
      start = i;
      chars = 0;
    }
    chars += len;
  }
  if (start < lines.length) out.add((start, lines.length));
  return out;
}

/// Reads a model's answer: `{"1": "…", "2": "…"}` as asked, or the older
/// `{"vi": [...]}` / bare array with exactly [count] items. The answer may
/// be wrapped in a code fence or chatter. Lines it does not give are null.
List<String?> parseTranslations(String content, int count) {
  final out = List<String?>.filled(count, null);
  final start = content.indexOf(RegExp(r'[\[{]'));
  if (start < 0) return out;
  final open = content[start];
  final end = content.lastIndexOf(open == '{' ? '}' : ']');
  if (end <= start) return out;
  Object? decoded;
  try {
    decoded = jsonDecode(content.substring(start, end + 1));
  } catch (_) {
    return out;
  }
  if (decoded is Map) {
    var numbered = false;
    for (final e in decoded.entries) {
      final i = int.tryParse('${e.key}'.trim());
      if (i != null && i >= 1 && i <= count && e.value is String) {
        final t = (e.value as String).trim();
        if (t.isNotEmpty) out[i - 1] = t;
        numbered = true;
      }
    }
    if (numbered) return out;
    decoded = decoded['vi'] ?? decoded.values.whereType<List>().firstOrNull;
  }
  if (decoded is List && decoded.length == count) {
    for (var i = 0; i < count; i++) {
      final t = '${decoded[i]}'.trim();
      if (t.isNotEmpty) out[i] = t;
    }
  }
  return out;
}

class _Waiting {
  _Waiting(this.text, this.lang);
  final String text;
  final String lang;
  final since = DateTime.now();
  final done = Completer<String>();
}

class _Retry implements Exception {
  _Retry(this.message);
  final String message;
  @override
  String toString() => message;
}
