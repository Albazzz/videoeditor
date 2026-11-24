import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video/services/vercel_credits.dart';
import 'package:video/widgets/vercel_credits.dart';

void main() {
  test(
    'reads USD and separate Token Pass using only the credits endpoint',
    () async {
      final client = MockClient((request) async {
        expect(request.method, 'GET');
        expect(
          request.url.toString(),
          'https://ai-gateway.vercel.sh/v1/credits',
        );
        expect(request.headers['Authorization'], 'Bearer sample-key');
        expect(request.followRedirects, false);
        return http.Response(
          jsonEncode({
            'balance': '95.501234',
            'total_used': '4.50',
            'token_pass': {
              'remaining': '12.34',
              'resets_at': '2026-12-01T00:00:00Z',
            },
          }),
          200,
        );
      });
      addTearDown(client.close);
      final credits = await VercelCreditsApi.fetch(
        ' sample-key ',
        client: client,
      );
      expect(credits.balance, 95.501234);
      expect(credits.totalUsed, 4.5);
      expect(credits.tokenPassRemaining, 12.34);
      expect(credits.tokenPassResetsAt, DateTime.utc(2026, 12));
    },
  );

  test(
    'zero, negative, and unavailable pass balances retain their meaning',
    () {
      final credits = VercelCredits.fromJson({
        'balance': '-0.25',
        'total_used': 10,
        'token_pass': {'remaining': null},
      });
      expect(credits.balance, -0.25);
      expect(credits.hasTokenPass, true);
      expect(credits.tokenPassRemaining, isNull);
      expect(
        VercelCredits.fromJson({'balance': 0, 'total_used': '0'}).balance,
        0,
      );
      for (final invalid in [null, 'unknown', 'NaN', 'Infinity', true]) {
        expect(
          () => VercelCredits.fromJson({'balance': invalid, 'total_used': '0'}),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'authentication and malformed responses never become a zero balance or echo a key',
    () async {
      for (final status in [401, 403, 429, 500, 302]) {
        final client = MockClient(
          (_) async => http.Response('sample-secret', status),
        );
        addTearDown(client.close);
        await expectLater(
          VercelCreditsApi.fetch('sample-secret', client: client),
          throwsA(
            isA<VercelCreditsError>().having(
              (e) => e.message,
              'message',
              isNot(contains('sample-secret')),
            ),
          ),
        );
      }
      final malformed = MockClient(
        (_) async => http.Response('{"total_used":"1"}', 200),
      );
      addTearDown(malformed.close);
      await expectLater(
        VercelCreditsApi.fetch('key', client: malformed),
        throwsA(isA<VercelCreditsError>()),
      );
    },
  );

  testWidgets(
    'opens with balance, refreshes, and labels old data after an error',
    (tester) async {
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VercelCreditsPanel(
              apiKey: 'key',
              fetch: (_) async {
                if (++requests > 1) {
                  throw const VercelCreditsError('Mất kết nối');
                }
                return const VercelCredits(balance: 1.2345, totalUsed: 0.7655);
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Còn lại: 1.2345 USD'), findsOneWidget);
      expect(find.text('Tổng đã dùng: 0.7655 USD'), findsOneWidget);
      await tester.tap(find.byTooltip('Cập nhật số dư'));
      await tester.pumpAndSettle();
      expect(requests, 2);
      expect(find.text('Số dư lần cập nhật trước: 1.2345 USD'), findsOneWidget);
      expect(find.text('Mất kết nối'), findsOneWidget);
      expect(find.byTooltip('Thử lại số dư'), findsOneWidget);
    },
  );

  testWidgets('key changes discard the old balance and late responses', (
    tester,
  ) async {
    final old = Completer<VercelCredits>();
    final next = Completer<VercelCredits>();
    final keys = <String>[];
    Widget panel(String key) => MaterialApp(
      home: Scaffold(
        body: VercelCreditsPanel(
          apiKey: key,
          fetch: (key) {
            keys.add(key);
            return key == 'old' ? old.future : next.future;
          },
        ),
      ),
    );
    await tester.pumpWidget(panel('old'));
    await tester.pumpWidget(panel('next'));
    next.complete(const VercelCredits(balance: 2, totalUsed: 3));
    await tester.pumpAndSettle();
    old.complete(const VercelCredits(balance: 100, totalUsed: 0));
    await tester.pumpAndSettle();
    expect(keys, ['old', 'next']);
    expect(find.text('Còn lại: 2.0000 USD'), findsOneWidget);
    expect(find.text('Còn lại: 100.0000 USD'), findsNothing);
    await tester.pumpWidget(panel(''));
    await tester.pumpAndSettle();
    expect(find.textContaining('Còn lại:'), findsNothing);
    expect(keys, ['old', 'next']);
    expect(
      find.text('Thêm key Vercel AI Gateway để xem số dư.'),
      findsOneWidget,
    );
  });
}
