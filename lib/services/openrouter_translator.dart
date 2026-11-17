import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
    'mistralai/mistral-small-3.2-24b-instruct',
    'Mistral Small 3.2',
    'Mặc định: ít bị chặn nội dung, dịch Trung/Nhật khá · ~300đ một phim',
  ),
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
    'mistralai/mistral-nemo',
    'Mistral Nemo',
    'Rẻ nhất (~60đ một phim), nhanh',
  ),
  OpenRouterModel(
    'google/gemma-4-31b-it:free',
    'Gemma 4 31B (miễn phí)',
    'Không mất tiền nhưng bị giới hạn số lần gọi mỗi ngày',
  ),
];

const kDefaultOpenRouterModel = 'mistralai/mistral-small-3.2-24b-instruct';

/// Prices as listed by Vercel AI Gateway in November 2026. The first is
/// the default.
const kVercelModels = [
  OpenRouterModel(
    'mistral/mistral-small',
    'Mistral Small',
    'Mặc định: ít bị chặn nội dung, dịch Trung/Nhật khá · ~600đ một phim',
  ),
  OpenRouterModel(
    'mistral/mistral-nemo',
    'Mistral Nemo',
    'Rẻ nhất (~60đ một phim), nhanh',
  ),
  OpenRouterModel(
    'alibaba/qwen3.7-flash',
    'Qwen 3.7 Flash',
    'Rẻ nhất, giỏi tiếng Trung/Nhật · ~150đ một phim',
  ),
  OpenRouterModel(
    'deepseek/deepseek-v4-flash',
    'DeepSeek V4 Flash',
    'Rất giỏi tiếng Trung, rẻ · ~300đ một phim',
  ),
  OpenRouterModel(
    'google/gemini-3.1-flash-lite',
    'Gemini 3.1 Flash Lite',
    'Dịch tự nhiên hơn · ~1.500đ một phim',
  ),
  OpenRouterModel(
    'openai/gpt-5-nano',
    'GPT-5 Nano',
    'Rẻ, ổn với tiếng Nhật · ~300đ một phim',
  ),
];

/// A service that runs language models behind an OpenAI-style
/// chat-completions API.
class AiProvider {
  const AiProvider({
    required this.id,
    required this.name,
    required this.endpoint,
    required this.models,
    required this.keyHelp,
    required this.keyHint,
  });

  /// Stored in Settings as the translation engine.
  final String id;
  final String name;
  final String endpoint;
  final List<OpenRouterModel> models;

  /// Where the user gets a key.
  final String keyHelp;
  final String keyHint;

  String get defaultModel => models.first.id;
}

const kOpenRouter = AiProvider(
  id: 'openrouter',
  name: 'OpenRouter',
  endpoint: 'https://openrouter.ai/api/v1/chat/completions',
  models: kOpenRouterModels,
  keyHelp: 'Tạo key ở openrouter.ai → Keys',
  keyHint: 'sk-or-v1-…',
);

const kVercel = AiProvider(
  id: 'vercel',
  name: 'Vercel AI Gateway',
  endpoint: 'https://ai-gateway.vercel.sh/v1/chat/completions',
  models: kVercelModels,
  keyHelp: 'Tạo key ở vercel.com → AI Gateway → API Keys',
  keyHint: 'Khoá API của AI Gateway',
);

const kAiProviders = [kOpenRouter, kVercel];

AiProvider? aiProviderById(String id) {
  for (final p in kAiProviders) {
    if (p.id == id) return p;
  }
  return null;
}

/// Raised for problems retrying will not fix (wrong key, no credit).
class OpenRouterError implements Exception {
  const OpenRouterError(
    this.message, {
    this.account = false,
    this.blocked = false,
  });
  final String message;

  /// The key or the balance is the problem: no request will work until
  /// the user fixes it.
  final bool account;
  final bool blocked;
  @override
  String toString() => message;
}

/// Normal termination when the user stops subtitles, not a service failure.
class TranslationCancelled extends OpenRouterError {
  const TranslationCancelled() : super('Đã dừng dịch');
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

/// Translates subtitles with a language model on OpenRouter or another
/// [AiProvider] with the same API.
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
    this.provider = kOpenRouter,
    http.Client? client,
    this.gatherFor = const Duration(milliseconds: 1500),
    this.budget = 1000,
    this.maxLines = 40,
    this.parallel = 3,
    this.retryDelay = const Duration(seconds: 2),
    this.requestTimeout = const Duration(seconds: 90),
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null;

  final String apiKey;
  final String model;
  final AiProvider provider;
  String get _logTag => provider.id;
  final Duration gatherFor;

  /// Characters of original text per request: Chinese or Japanese lines
  /// are short in characters but dense, so this is about 30–80 lines.
  final int budget;
  final int maxLines;

  /// Requests in flight at once.
  final int parallel;

  /// First wait before retrying; doubled each time.
  final Duration retryDelay;
  final Duration requestTimeout;

  final http.Client _client;
  final bool _ownsClient;
  late final _endpoint = Uri.parse(provider.endpoint);

  final _waiting = <_Waiting>[];
  int _waitingChars = 0;
  Timer? _gather;
  bool _disposed = false;
  int _inFlight = 0;
  final _slots = <Completer<void>>[];
  final _cancel = Completer<void>();
  final _active = <_Waiting>{};
  OpenRouterError? _fatal;
  DateTime _nextRequest = DateTime(0);
  Duration _requestSpacing = Duration.zero;
  bool _structured = true;

  void _checkActive() {
    if (_disposed) throw const TranslationCancelled();
    if (_fatal != null) throw _fatal!;
  }

  Future<T> _untilCancelled<T>(Future<T> work) => Future.any([
    work,
    _cancel.future.then<T>((_) => throw const TranslationCancelled()),
  ]);

  Future<void> _wait(Duration duration) async {
    _checkActive();
    if (duration <= Duration.zero) return;
    final done = Completer<void>();
    final timer = Timer(duration, done.complete);
    try {
      await _untilCancelled(done.future);
    } finally {
      timer.cancel();
    }
    _checkActive();
  }

  Future<void> _waitForTurn() async {
    while (true) {
      _checkActive();
      final delay = _nextRequest.difference(DateTime.now());
      if (delay > Duration.zero) {
        await _wait(delay);
        continue;
      }
      _nextRequest = DateTime.now().add(_requestSpacing);
      return;
    }
  }

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
    if (_disposed) return Future.error(const TranslationCancelled());
    if (_fatal != null) return Future.error(_fatal!);
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
      _active.addAll(items);
      final context = List.of(_recent);
      _liveRequests++;
      _translateChunk([for (final w in items) w.text], entry.key, context)
          .then(
            (out) {
              for (var i = 0; i < items.length; i++) {
                if (items[i].done.isCompleted) continue;
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
                if (!w.done.isCompleted) w.done.completeError(e);
              }
            },
          )
          .whenComplete(() {
            _active.removeAll(items);
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
    _checkActive();
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
    AppLog.i(_logTag, 'Hỏi lại ${missing.length} câu bị bỏ sót');
    for (var k = 0; k < missing.length; k += maxLines) {
      _checkActive();
      final group = missing.sublist(
        k,
        k + maxLines < missing.length ? k + maxLines : missing.length,
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
    _checkActive();
    while (_inFlight >= parallel) {
      final c = Completer<void>();
      _slots.add(c);
      await _untilCancelled(c.future);
      _checkActive();
    }
    _inFlight++;
  }

  void _release() {
    _inFlight--;
    // Wake all contenders: after a fatal account error each must be able
    // to leave without acquiring a slot or waiting for another release.
    final slots = List.of(_slots);
    _slots.clear();
    for (final slot in slots) {
      slot.complete();
    }
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
      await _waitForTurn();
      final started = DateTime.now();
      try {
        final abort = Completer<void>();
        final request =
            http.AbortableRequest(
                'POST',
                _endpoint,
                abortTrigger: Future.any([abort.future, _cancel.future]),
              )
              ..headers.addAll({
                'Authorization': 'Bearer $apiKey',
                'Content-Type': 'application/json',
                'X-Title': 'AIcall app',
              });
        request.body = jsonEncode({
          'model': model,
          'messages': messages(lines, lang, context),
          'temperature': 0.3,
          'max_tokens':
              (lines.fold<int>(0, (n, l) => n + l.length) * 2 +
                      lines.length * 16 +
                      512)
                  .clamp(1024, 4096),
          if (_structured)
            'response_format': {
              'type': 'json_schema',
              'json_schema': {
                'name': 'subtitles',
                'strict': true,
                'schema': {
                  'type': 'object',
                  'properties': {
                    for (var i = 1; i <= lines.length; i++)
                      '$i': {'type': 'string'},
                  },
                  'required': [for (var i = 1; i <= lines.length; i++) '$i'],
                  'additionalProperties': false,
                },
              },
            },
        });
        final http.Response res;
        try {
          res =
              await _untilCancelled(
                _client.send(request).then(http.Response.fromStream),
              ).timeout(
                requestTimeout,
                onTimeout: () {
                  if (!abort.isCompleted) abort.complete();
                  throw TimeoutException(
                    'Máy chủ dịch phản hồi quá chậm',
                    requestTimeout,
                  );
                },
              );
        } finally {
          if (!abort.isCompleted) abort.complete();
        }
        _checkActive();
        final ms = DateTime.now().difference(started).inMilliseconds;
        final code = res.statusCode;
        if (code == 401 || code == 403) {
          throw OpenRouterError(
            'Key ${provider.name} không đúng hoặc đã bị thu hồi',
            account: true,
          );
        }
        if (code == 402) {
          throw OpenRouterError(
            'Tài khoản ${provider.name} hết tiền, nạp thêm hoặc chọn model rẻ hơn',
            account: true,
          );
        }
        if (code == 400 || code == 404) {
          final detail = _errorText(res.body);
          // Custom models may not implement structured outputs. Retry once
          // without that option; never treat moderation as format trouble.
          if (code == 400 &&
              _structured &&
              RegExp(
                r'response_format|json_schema|structured.output',
                caseSensitive: false,
              ).hasMatch(detail) &&
              !detail.contains('DataInspectionFailed')) {
            _structured = false;
            if (attempt < attempts) continue;
          }
          final blocked =
              detail.contains('DataInspectionFailed') ||
              detail.contains('content_filter');
          throw OpenRouterError(
            blocked
                ? '${provider.name}: nhà cung cấp chặn nội dung ($code), tạm hiện câu gốc'
                : '${provider.name} từ chối ($code): $detail',
            blocked: blocked,
          );
        }
        if (code == 429) {
          final detail = _errorText(res.body);
          final limit = RegExp(
            r'limit of (\d+) requests per minute',
          ).firstMatch(detail);
          final rpm = int.tryParse(limit?[1] ?? '');
          if (rpm != null && rpm > 0) {
            _requestSpacing = Duration(
              milliseconds: (60000 / rpm).ceil() + 100,
            );
          }
          final delay =
              retryAfter(res.headers['retry-after'], detail) ??
              retryDelay * (1 << (attempt - 1));
          final next = DateTime.now().add(delay);
          if (next.isAfter(_nextRequest)) _nextRequest = next;
          throw _Retry('${provider.name} giới hạn tần suất (429): $detail');
        }
        if (code != 200) {
          throw _Retry('${provider.name} lỗi $code: ${_errorText(res.body)}');
        }
        final body = jsonDecode(utf8.decode(res.bodyBytes));
        if (body is Map && body['error'] != null) {
          throw _Retry('${provider.name}: ${_errorText(res.body)}');
        }
        final choices = body is Map ? body['choices'] : null;
        final choice =
            choices is List && choices.isNotEmpty && choices.first is Map
            ? choices.first as Map
            : null;
        if (choice?['finish_reason'] == 'content_filter') {
          throw OpenRouterError(
            '${provider.name}: nhà cung cấp chặn nội dung, tạm hiện câu gốc',
            blocked: true,
          );
        }
        final message = choice?['message'];
        final content = message is Map && message['content'] is String
            ? message['content'] as String
            : '';
        if (message is Map && message['refusal'] != null) {
          throw OpenRouterError(
            '${provider.name}: model từ chối dịch nội dung này, tạm hiện câu gốc',
            blocked: true,
          );
        }
        final usage = body['usage'];
        final parsed = parseTranslations(content, lines.length);
        final got = parsed.where((t) => t != null).length;
        AppLog.i(
          _logTag,
          '$got/${lines.length} câu (${lines.fold(0, (n, l) => n + l.length)} '
          'ký tự) trong ${(ms / 1000).toStringAsFixed(1)} giây'
          '${usage is Map ? ' · ${usage['prompt_tokens']}+${usage['completion_tokens']} token' : ''}',
        );
        if (got == 0) {
          AppLog.e(
            _logTag,
            'Không đọc được câu trả lời: '
            '${content.length > 300 ? content.substring(0, 300) : content}',
          );
        }
        return parsed;
      } on OpenRouterError catch (e) {
        if (e is TranslationCancelled) rethrow;
        if (e.account) {
          _fatal = e;
          for (final w in _waiting) {
            if (!w.done.isCompleted) w.done.completeError(e);
          }
          _waiting.clear();
          _waitingChars = 0;
        }
        AppLog.e(_logTag, e.message);
        rethrow;
      } catch (e) {
        _checkActive();
        if (attempt >= attempts || _disposed) {
          AppLog.e(_logTag, 'Bỏ sau $attempt lần: $e');
          throw OpenRouterError('Không dịch được qua ${provider.name}: $e');
        }
        var wait = retryDelay * (1 << (attempt - 1));
        final cooldown = _nextRequest.difference(DateTime.now());
        if (cooldown > wait) wait = cooldown;
        AppLog.i(
          _logTag,
          'Lần $attempt lỗi ($e), thử lại sau ${wait.inSeconds} giây',
        );
        await _wait(wait);
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
    if (_disposed) return;
    _disposed = true;
    _cancel.complete();
    _gather?.cancel();
    for (final w in [..._waiting, ..._active]) {
      if (!w.done.isCompleted) {
        w.done.completeError(const TranslationCancelled());
      }
    }
    _waiting.clear();
    _waitingChars = 0;
    if (_ownsClient) _client.close();
  }
}

/// Accept both HTTP Retry-After forms and provider messages such as
/// "Retry after 35s". A malformed value falls back to normal backoff.
Duration? retryAfter(String? header, String message, {DateTime? now}) {
  final seconds = double.tryParse(header ?? '');
  if (seconds != null && seconds.isFinite && seconds >= 0) {
    return Duration(milliseconds: (seconds * 1000).ceil());
  }
  if (header != null) {
    try {
      final delay = HttpDate.parse(header).difference(now ?? DateTime.now());
      return delay.isNegative ? Duration.zero : delay;
    } catch (_) {}
  }
  final match = RegExp(
    r'retry after\s+(\d+(?:\.\d+)?)\s*s',
    caseSensitive: false,
  ).firstMatch(message);
  return match == null
      ? null
      : Duration(milliseconds: (double.parse(match[1]!) * 1000).ceil());
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
  Object? decoded;
  try {
    if (end <= start) throw const FormatException('truncated JSON');
    decoded = jsonDecode(content.substring(start, end + 1));
  } catch (_) {
    // Preserve complete numbered strings from a malformed/truncated answer.
    // Each value still has to be a valid JSON string; never guess missing text.
    final pairs = RegExp(r'"(\d+)"\s*:\s*("(?:[^"\\]|\\.)*")');
    for (final m in pairs.allMatches(content.substring(start))) {
      final i = int.tryParse(m[1]!);
      if (i == null || i < 1 || i > count) continue;
      try {
        final text = (jsonDecode(m[2]!) as String).trim();
        if (text.isNotEmpty) out[i - 1] = text;
      } catch (_) {}
    }
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
      if (decoded[i] is! String) continue;
      final t = (decoded[i] as String).trim();
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
