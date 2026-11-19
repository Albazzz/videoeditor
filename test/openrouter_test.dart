import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video/services/openrouter_translator.dart';
import 'package:video/services/translator.dart';

/// A fake OpenRouter that "translates" by tagging each numbered line.
MockClient fakeServer({
  List<int> failFirst = const [],
  bool dropLast = false,
  List<Map<String, Object?>>? seen,
  Duration delay = Duration.zero,
  void Function(int inFlight)? onLoad,
  void Function(Uri url)? onUrl,
}) {
  var call = 0;
  var inFlight = 0;
  return MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, Object?>;
    seen?.add(body);
    onUrl?.call(req.url);
    if (call < failFirst.length) {
      return http.Response('{"error":{"message":"busy"}}', failFirst[call++]);
    }
    call++;
    inFlight++;
    onLoad?.call(inFlight);
    await Future<void>.delayed(delay);
    inFlight--;
    final user = (body['messages'] as List).last['content'] as String;
    final data = jsonDecode(user.substring(user.lastIndexOf('{"lines"')));
    final lines = (data['lines'] as Map).cast<String, String>();
    final out = {for (final e in lines.entries) e.key: 'VI:${e.value}'};
    if (dropLast && lines.length > 1) out.remove('${lines.length}');
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {'content': '```json\n${jsonEncode(out)}\n```'},
            },
          ],
          'usage': {'prompt_tokens': 10, 'completion_tokens': 5},
        }),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
}

OpenRouterTranslator make(http.Client client, {int maxLines = 3}) =>
    OpenRouterTranslator(
      apiKey: 'k',
      model: 'm',
      client: client,
      maxLines: maxLines,
      gatherFor: const Duration(milliseconds: 20),
      retryDelay: const Duration(milliseconds: 1),
    );

void main() {
  setUp(OpenRouterTranslator.resetRateLimits);
  test('Retry-After accepts seconds, dates and provider error text', () {
    final now = DateTime.utc(2026, 11, 17);
    expect(retryAfter('1.5', ''), const Duration(milliseconds: 1500));
    expect(
      retryAfter(
        HttpDate.format(now.add(const Duration(seconds: 35))),
        '',
        now: now,
      ),
      const Duration(seconds: 35),
    );
    expect(
      retryAfter(null, 'Rate limited. Retry after 35s.'),
      const Duration(seconds: 35),
    );
    expect(
      retryAfter('invalid', 'Retry after 2s.'),
      const Duration(seconds: 2),
    );
    expect(retryAfter('-1', ''), isNull);
  });

  test('rate limit cooldown also holds newly queued requests', () async {
    var calls = 0;
    final limited = Completer<void>();
    final good = fakeServer();
    final times = <DateTime>[];
    final t = OpenRouterTranslator(
      apiKey: 'k',
      model: 'm',
      parallel: 1,
      gatherFor: Duration.zero,
      maxLines: 1,
      retryDelay: const Duration(milliseconds: 1),
      client: MockClient((req) async {
        times.add(DateTime.now());
        if (calls++ == 0) {
          limited.complete();
          return http.Response(
            '{"error":{"message":"busy"}}',
            429,
            headers: {'retry-after': '0.1'},
          );
        }
        return good.post(req.url, headers: req.headers, body: req.body);
      }),
    );
    addTearDown(t.dispose);
    final first = t.translate('a', 'zh');
    await limited.future;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(t.status.state, TranslationState.cooldown);
    expect(t.status.cooldownUntil, isNotNull);
    final second = t.translate('b', 'zh');
    expect(await Future.wait([first, second]), ['VI:a', 'VI:b']);
    expect(
      times[1].difference(times[0]).inMilliseconds,
      greaterThanOrEqualTo(90),
    );
  });

  test(
    'no credit stops a queued file after the first failed request',
    () async {
      var calls = 0;
      final t = OpenRouterTranslator(
        apiKey: 'k',
        model: 'm',
        parallel: 1,
        maxLines: 1,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 402);
        }),
      );
      addTearDown(t.dispose);
      await expectLater(
        t.translateBatch(List.filled(20, 'x'), 'zh'),
        throwsA(
          isA<OpenRouterError>().having((e) => e.account, 'account', true),
        ),
      );
      expect(calls, 1);
    },
  );

  test(
    'dispose settles active, queued and slot-waiting translations',
    () async {
      final started = Completer<void>();
      final response = Completer<http.Response>();
      var calls = 0;
      final t = OpenRouterTranslator(
        apiKey: 'k',
        model: 'm',
        parallel: 1,
        maxLines: 1,
        gatherFor: Duration.zero,
        client: MockClient((_) {
          calls++;
          if (!started.isCompleted) started.complete();
          return response.future;
        }),
      );
      final live = t.translate('one', 'zh');
      final queued = t.translate('two', 'zh');
      final file = t.translateBatch(['three', 'four'], 'zh');
      final checks = [
        expectLater(live, throwsA(isA<TranslationCancelled>())),
        expectLater(queued, throwsA(isA<TranslationCancelled>())),
        expectLater(file, throwsA(isA<TranslationCancelled>())),
      ];
      await started.future;
      await t.dispose();
      await Future.wait(checks).timeout(const Duration(seconds: 1));
      response.complete(http.Response('{}', 500));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(calls, 1);
    },
  );

  test(
    'dispose interrupts server-requested cooldown without another call',
    () async {
      final started = Completer<void>();
      var calls = 0;
      final t = make(
        MockClient((_) async {
          calls++;
          started.complete();
          return http.Response('{}', 429, headers: {'retry-after': '60'});
        }),
      );
      final result = expectLater(
        t.translateBatch(['x'], 'zh'),
        throwsA(isA<TranslationCancelled>()),
      );
      await started.future;
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await t.dispose();
      await result.timeout(const Duration(seconds: 1));
      expect(calls, 1);
    },
  );

  test('moderation is reported once without retrying that request', () async {
    var calls = 0;
    final t = make(
      MockClient((_) async {
        calls++;
        return http.Response(
          '{"error":{"message":"InternalError.Algo.DataInspectionFailed"}}',
          400,
        );
      }),
    );
    addTearDown(t.dispose);
    await expectLater(
      t.translateBatch(['a'], 'zh'),
      throwsA(isA<OpenRouterError>().having((e) => e.blocked, 'blocked', true)),
    );
    expect(calls, 1);
  });

  test(
    'unsupported structured outputs fall back to the ordinary prompt',
    () async {
      var calls = 0;
      final good = fakeServer();
      final t = make(
        MockClient((req) async {
          if (calls++ == 0) {
            return http.Response(
              '{"error":{"message":"response_format json_schema unsupported"}}',
              400,
            );
          }
          expect(jsonDecode(req.body).containsKey('response_format'), false);
          return good.post(req.url, headers: req.headers, body: req.body);
        }),
      );
      addTearDown(t.dispose);
      expect(await t.translateBatch(['a'], 'zh'), ['VI:a']);
      expect(calls, 2);
    },
  );

  test('keeps complete JSON strings in malformed or truncated output', () {
    expect(parseTranslations('{"1":"a","2":"b",","3":"unfinished', 3), [
      'a',
      'b',
      null,
    ]);
    expect(parseTranslations(r'{"1":"he said \"yes\"","2":"unfinished', 2), [
      'he said "yes"',
      null,
    ]);
    expect(parseTranslations('[null,42]', 2), [null, null]);
  });
  test('reads numbered answers, old-style lists, fences and chatter', () {
    expect(parseTranslations('Sure!\n```json\n{"1":"a","2":"b"}\n```', 2), [
      'a',
      'b',
    ]);
    // A skipped line is null, the others are kept.
    expect(parseTranslations('{"1":"a","3":"c"}', 3), ['a', null, 'c']);
    expect(parseTranslations('{"vi":["a","b"]}', 2), ['a', 'b']);
    expect(parseTranslations('["x"]', 1), ['x']);
    expect(parseTranslations('no json', 1), [null]);
  });

  test('requests are sized by text, never cutting a line', () {
    final lines = ['あ' * 600, 'い' * 600, 'う' * 600, 'え' * 2000, 'お'];
    expect(chunkByLength(lines, budget: 1500), [
      (0, 2),
      (2, 3),
      (3, 4),
      (4, 5),
    ]);
    final short = List.filled(200, '短句');
    expect(chunkByLength(short, budget: 1500, maxLines: 80), [
      (0, 80),
      (80, 160),
      (160, 200),
    ]);
    expect(chunkByLength(const []), isEmpty);
  });

  test('a long file goes in several requests at once, with context', () async {
    final seen = <Map<String, Object?>>[];
    var most = 0;
    final t = make(
      fakeServer(
        seen: seen,
        delay: const Duration(milliseconds: 30),
        onLoad: (n) => most = n > most ? n : most,
      ),
    );
    final progress = <int>[];
    final out = await t.translateBatch(
      ['一', '二', '三', '四', '五', '六', '七'],
      'zh',
      onProgress: progress.add,
    );
    expect(out, ['VI:一', 'VI:二', 'VI:三', 'VI:四', 'VI:五', 'VI:六', 'VI:七']);
    expect(seen.length, 3);
    expect(most, greaterThan(1), reason: 'requests should overlap');
    expect(progress.last, 7);
    final second = seen
        .map((b) => (b['messages'] as List).last['content'] as String)
        .firstWhere((c) => c.contains('"1":"四"'));
    expect(second, contains('for context only'));
    expect(second, contains('三'));
    expect(second, contains('Chinese'));
  });

  test('busy server is retried; a skipped line is asked for alone', () async {
    final t = make(fakeServer(failFirst: [429, 503]));
    expect(await t.translateBatch(['a', 'b'], 'ja'), ['VI:a', 'VI:b']);

    final seen = <Map<String, Object?>>[];
    final short = make(fakeServer(dropLast: true, seen: seen));
    expect(await short.translateBatch(['a', 'b', 'c'], 'ja'), [
      'VI:a',
      'VI:b',
      'VI:c',
    ]);
    expect(seen.length, 2);
    final again = (seen[1]['messages'] as List).last['content'] as String;
    expect(again, contains('"1":"c"'));
  });

  test('a wrong key fails at once with a clear message', () async {
    var calls = 0;
    final t = make(
      MockClient((_) async {
        calls++;
        return http.Response('{"error":{"message":"No auth"}}', 401);
      }),
    );
    await expectLater(
      t.translateBatch(['a'], 'ja'),
      throwsA(
        isA<OpenRouterError>()
            .having((e) => e.message, 'message', contains('Key'))
            .having((e) => e.account, 'account', isTrue),
      ),
    );
    expect(calls, 1);
  });

  test('a per-minute limit makes each turn carry every waiting line', () async {
    final good = fakeServer();
    final sizes = <int>[];
    var calls = 0;
    final t = OpenRouterTranslator(
      apiKey: 'k',
      model: 'limited',
      gatherFor: Duration.zero,
      holdFor: Duration.zero,
      retryDelay: const Duration(milliseconds: 1),
      client: MockClient((req) async {
        if (calls++ == 0) {
          return http.Response(
            '{"error":{"message":"this team\'s limit of 200 requests per minute was reached"}}',
            429,
            headers: {'retry-after': '0'},
          );
        }
        final prompt =
            (jsonDecode(req.body)['messages'] as List).last['content']
                as String;
        final lines =
            jsonDecode(
                  prompt.substring(prompt.lastIndexOf('{"lines"')),
                )['lines']
                as Map;
        sizes.add(lines.length);
        return good.post(req.url, headers: req.headers, body: req.body);
      }),
    );
    addTearDown(t.dispose);
    expect(await t.translate('first', 'en'), 'VI:first');
    // Lines heard one by one while waiting for the next turn (300 ms).
    final rest = <Future<String>>[];
    for (var i = 0; i < 6; i++) {
      rest.add(t.translate('line $i', 'en', start: 600.0 + i));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future.wait(rest);
    expect(sizes, [1, 6]);
  });

  test('lines far from the viewer wait to fill a request', () async {
    final sizes = <int>[];
    final good = fakeServer(seen: null);
    final t = OpenRouterTranslator(
      apiKey: 'k',
      model: 'm',
      gatherFor: const Duration(milliseconds: 10),
      holdFor: const Duration(milliseconds: 400),
      client: MockClient((req) async {
        final prompt =
            (jsonDecode(req.body)['messages'] as List).last['content']
                as String;
        sizes.add(
          (jsonDecode(prompt.substring(prompt.lastIndexOf('{"lines"')))['lines']
                  as Map)
              .length,
        );
        return good.post(req.url, headers: req.headers, body: req.body);
      }),
    );
    addTearDown(t.dispose);
    t.position = 0;
    final all = <Future<String>>[];
    for (var i = 0; i < 5; i++) {
      all.add(t.translate('far $i', 'en', start: 900.0 + i * 3));
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    await Future.wait(all);
    expect(sizes, [5]);
  });

  test(
    'an idle queue sends four immediately or one after the short gather window',
    () async {
      final t = OpenRouterTranslator(
        apiKey: '',
        model: 'test',
        gatherFor: const Duration(minutes: 1),
        client: fakeServer(),
      );
      addTearDown(t.dispose);
      final lines = [for (var i = 0; i < 3; i++) t.translate('line $i', 'en')];
      expect(t.status.queued, 3);
      lines.add(t.translate('fourth', 'en'));
      expect(t.status.linesInFlight, 4);
      await Future.wait(lines);
      expect(
        await t.translate('fifth', 'en').timeout(const Duration(seconds: 2)),
        'VI:fifth',
      );
      expect(t.status.done, 5);
    },
  );

  test(
    'a seek prioritises lines close to the viewer in the next request',
    () async {
      final good = fakeServer();
      final gate = Completer<void>();
      final batches = <List<String>>[];
      final t = OpenRouterTranslator(
        apiKey: '',
        model: 'test',
        parallel: 1,
        maxLines: 2,
        client: MockClient((req) async {
          final prompt =
              (jsonDecode(req.body)['messages'] as List).last['content']
                  as String;
          final lines =
              jsonDecode(
                    prompt.substring(prompt.lastIndexOf('{"lines"')),
                  )['lines']
                  as Map;
          batches.add(lines.values.cast<String>().toList());
          if (batches.length == 1) await gate.future;
          return good.post(req.url, headers: req.headers, body: req.body);
        }),
      );
      addTearDown(t.dispose);
      final pending = [
        t.translate('first', 'en'),
        t.translate('second', 'en'),
        t.translate('far', 'en', start: 250),
        t.translate('next', 'en', start: 105),
        t.translate('near', 'en', start: 110),
      ];
      t.position = 100;
      gate.complete();
      await Future.wait(pending);
      expect(batches, [
        ['first', 'second'],
        ['next', 'near'],
        ['far'],
      ]);
    },
  );

  test('a moderated line leaves its neighbours translatable', () async {
    final good = fakeServer();
    final t = OpenRouterTranslator(
      apiKey: '',
      model: 'test',
      client: MockClient((req) async {
        if (req.body.contains('REJECT_THIS')) {
          return http.Response('{"error":{"message":"content_filter"}}', 400);
        }
        return good.post(req.url, headers: req.headers, body: req.body);
      }),
    );
    addTearDown(t.dispose);
    final goodLine = t.translate('good', 'en');
    await expectLater(
      t.translate('REJECT_THIS', 'en'),
      throwsA(isA<OpenRouterError>()),
    );
    expect(await goodLine, 'VI:good');
    expect(t.status.blocked, 1);
    expect(t.status.done, 1);
  });

  test('live lines heard together go in one request', () async {
    final seen = <Map<String, Object?>>[];
    final t = make(fakeServer(seen: seen), maxLines: 80);
    final results = await Future.wait([
      t.translate('a', 'ja'),
      t.translate('b', 'ja'),
    ]);
    expect(results, ['VI:a', 'VI:b']);
    expect(seen.length, 1);
    // A line heard again is not sent again.
    expect(await t.translate('a', 'ja'), 'VI:a');
    expect(seen.length, 1);
    await t.dispose();
  });

  test('a backlog of live lines goes in a few big requests', () async {
    final seen = <Map<String, Object?>>[];
    final t = OpenRouterTranslator(
      apiKey: 'k',
      model: 'm',
      client: fakeServer(seen: seen, delay: const Duration(milliseconds: 200)),
      gatherFor: const Duration(milliseconds: 20),
      parallel: 1,
      retryDelay: const Duration(milliseconds: 1),
    );
    // Heard far faster than one slow request at a time can carry singly.
    final futures = <Future<String>>[];
    for (var i = 0; i < 60; i++) {
      futures.add(t.translate('câu $i', 'ja'));
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final out = await Future.wait(futures);
    expect(out.first, 'VI:câu 0');
    expect(out.last, 'VI:câu 59');
    expect(seen.length, lessThanOrEqualTo(4));
    await t.dispose();
  });

  test('no credit is an account problem (the app falls back)', () async {
    final t = make(
      MockClient(
        (_) async => http.Response('{"error":{"message":"credits"}}', 402),
      ),
    );
    await expectLater(
      t.translateBatch(['a'], 'ja'),
      throwsA(
        isA<OpenRouterError>()
            .having((e) => e.account, 'account', isTrue)
            .having((e) => e.message, 'message', contains('hết tiền')),
      ),
    );
  });

  test('Vercel AI Gateway: same requests, its own address and name', () async {
    Uri? sentTo;
    final t = OpenRouterTranslator(
      provider: kVercel,
      apiKey: 'k',
      model: kVercel.defaultModel,
      client: fakeServer(onUrl: (u) => sentTo = u),
      retryDelay: const Duration(milliseconds: 1),
    );
    expect(await t.translateBatch(['你好'], 'zh'), ['VI:你好']);
    expect(
      sentTo.toString(),
      'https://ai-gateway.vercel.sh/v1/chat/completions',
    );

    final broke = OpenRouterTranslator(
      provider: kVercel,
      apiKey: 'k',
      model: 'm',
      client: MockClient((_) async => http.Response('{}', 401)),
    );
    await expectLater(
      broke.translateBatch(['a'], 'ja'),
      throwsA(
        isA<OpenRouterError>().having(
          (e) => e.message,
          'message',
          contains('Vercel AI Gateway'),
        ),
      ),
    );
    expect(aiProviderById('vercel'), kVercel);
    expect(aiProviderById('device'), isNull);
  });
}
