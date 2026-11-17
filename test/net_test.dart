import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video/services/net.dart';

void main() {
  test('transient failures retry while permission errors do not', () async {
    var calls = 0;
    final client = MockClient(
      (_) async => http.Response('body', ++calls == 1 ? 503 : 200),
    );
    final res = await Net.get(
      Uri.parse('https://cdn.example/segment'),
      {},
      client: client,
    );
    expect(res.$1, 200);
    expect(calls, 2);
    calls = 0;
    final forbidden = MockClient((_) async {
      calls++;
      return http.Response('', 403);
    });
    expect(
      (await Net.get(
        Uri.parse('https://cdn.example/segment'),
        {},
        client: forbidden,
      )).$1,
      403,
    );
    expect(calls, 1);
  });

  test('a range-ignoring server cannot buffer the whole movie', () async {
    final client = MockClient((_) async => http.Response('x' * 1024, 200));
    await expectLater(
      Net.fetch(
        Uri.parse('https://cdn.example/video.mp4'),
        {'Range': 'bytes=0-31'},
        client: client,
        maxBytes: 32,
      ),
      throwsException,
    );
  });
}
