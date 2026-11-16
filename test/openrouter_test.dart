import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video/services/openrouter_translator.dart';

/// A fake OpenRouter that "translates" by tagging each line.
MockClient fakeServer({
  List<int> failFirst = const [],
  bool wrongCount = false,
  List<Map<String, Object?>>? seen,
}) {
  var call = 0;
  return MockClient((req) async {
    final body = jsonDecode(req.body) as Map<String, Object?>;
    seen?.add(body);
    if (call < failFirst.length) {
      return http.Response('{"error":{"message":"busy"}}', failFirst[call++]);
    }
    call++;
    final user = (body['messages'] as List).last['content'] as String;
    final data = jsonDecode(user.substring(user.lastIndexOf('{"lines"')));
    final lines = (data['lines'] as List).cast<String>();
    final out = [for (final l in lines) 'VI:$l'];
    if (wrongCount && lines.length > 1) out.removeLast();
    return http.Response.bytes(
      utf8.encode(
        jsonEncode({
          'choices': [
            {
              'message': {
                'content': '```json\n${jsonEncode({'vi': out})}\n```',
              },
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

OpenRouterTranslator make(http.Client client) => OpenRouterTranslator(
  apiKey: 'k',
  model: 'm',
  client: client,
  chunkSize: 3,
  gatherFor: const Duration(milliseconds: 20),
  retryDelay: const Duration(milliseconds: 1),
);

void main() {
  test('reads answers wrapped in fences or chatter', () {
    expect(parseTranslations('Sure!\n```json\n{"vi":["a","b"]}\n```', 2), [
      'a',
      'b',
    ]);
    expect(parseTranslations('["x"]', 1), ['x']);
    expect(parseTranslations('{"vi":["a"]}', 2), isNull);
    expect(parseTranslations('no json', 1), isNull);
  });

  test('a long file goes in chunks, each with the lines before it', () async {
    final seen = <Map<String, Object?>>[];
    final t = make(fakeServer(seen: seen));
    final progress = <int>[];
    final out = await t.translateBatch(
      ['一', '二', '三', '四', '五', '六', '七'],
      'zh',
      onProgress: progress.add,
    );
    expect(out, ['VI:一', 'VI:二', 'VI:三', 'VI:四', 'VI:五', 'VI:六', 'VI:七']);
    expect(seen.length, 3);
    expect(progress, [3, 6, 7]);
    final second = (seen[1]['messages'] as List).last['content'] as String;
    expect(second, contains('for context only'));
    expect(second, contains('VI:三'));
    expect(second, contains('Chinese'));
  });

  test('busy server and dropped lines are retried', () async {
    final t = make(fakeServer(failFirst: [429, 503]));
    expect(await t.translateBatch(['a', 'b'], 'ja'), ['VI:a', 'VI:b']);

    // The model returns one line short: halves until each line fits.
    final short = make(fakeServer(wrongCount: true));
    expect(await short.translateBatch(['a', 'b', 'c'], 'ja'), [
      'VI:a',
      'VI:b',
      'VI:c',
    ]);
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
    final t = make(fakeServer(seen: seen));
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
