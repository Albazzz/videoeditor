import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video/services/openrouter_translator.dart';

/// A fake OpenRouter that "translates" by tagging each numbered line.
MockClient fakeServer({
  List<int> failFirst = const [],
  bool dropLast = false,
  List<Map<String, Object?>>? seen,
  Duration delay = Duration.zero,
  void Function(int inFlight)? onLoad,
}) {
  var call = 0;
  var inFlight = 0;
  return MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, Object?>;
    seen?.add(body);
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
        isA<OpenRouterError>().having(
          (e) => e.message,
          'message',
          contains('Key'),
        ),
      ),
    );
    expect(calls, 1);
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
}
