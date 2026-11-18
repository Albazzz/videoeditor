import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/app_settings.dart';
import 'package:video/widgets/subtitle_revision.dart';

void main() {
  testWidgets('one-line revision previews before apply and restores on undo', (
    tester,
  ) async {
    final previousEngine = appSettings.translateEngine;
    final previousKey = appSettings.openRouterKey;
    appSettings.translateEngine = 'openrouter';
    appSettings.openRouterKey = 'test';
    addTearDown(() {
      appSettings.translateEngine = previousEngine;
      appSettings.openRouterKey = previousKey;
    });
    var cues = [
      const Cue(start: 0, end: 1, text: 'Trước đó', source: 'Before'),
      const Cue(start: 2, end: 4, text: 'Bản cũ', source: 'Original sentence'),
    ];
    final requests = <Map<String, dynamic>>[];
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => showSubtitleRevision(
                    context,
                    videoId: 'video-A',
                    language: 'en',
                    initialIndex: 1,
                    currentCues: () => cues,
                    onApply: (next) async => cues = next,
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        final instruction = find.byWidgetPredicate(
          (w) =>
              w is TextField && w.decoration?.labelText == 'Yêu cầu dịch lại',
        );
        await tester.enterText(instruction, 'Đổi xưng hô thành anh–em');
        // Recognition can insert an earlier sentence while this form is open.
        cues = [
          cues.first,
          const Cue(
            start: 1,
            end: 1.5,
            text: 'New earlier cue',
            source: 'Added',
          ),
          cues.last,
        ];
        await tester.ensureVisible(find.text('Tạo bản dịch mới'));
        await tester.tap(find.text('Tạo bản dịch mới'));
        await tester.pumpAndSettle();
        expect(cues.last.text, 'Bản cũ');
        expect(find.text('Cũ: Bản cũ'), findsOneWidget);
        expect(find.text('Mới: Bản dịch mới'), findsOneWidget);
        final messages = requests.single['messages'] as List;
        expect(messages.first['content'], contains('Đổi xưng hô thành anh–em'));
        expect(messages.first['content'], contains('Do not censor'));
        expect(messages.last['content'], contains('Before'));
        expect(messages.last['content'], contains('Original sentence'));
        await tester.ensureVisible(find.text('Áp dụng'));
        await tester.tap(find.text('Áp dụng'));
        await tester.pumpAndSettle();
        expect(cues.last.text, 'Bản dịch mới');
        expect(cues.last.source, 'Original sentence');
        expect((cues.last.start, cues.last.end), (2.0, 4.0));
        expect(cues[0].text, 'Trước đó');
        await tester.ensureVisible(find.text('Hoàn tác'));
        await tester.tap(find.text('Hoàn tác'));
        await tester.pumpAndSettle();
        expect(cues.last.text, 'Bản cũ');
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
      () => MockClient((request) async {
        requests.add(jsonDecode(request.body) as Map<String, dynamic>);
        return http.Response.bytes(
          utf8.encode(
            jsonEncode({
              'choices': [
                {
                  'message': {
                    'content': jsonEncode({'1': 'Bản dịch mới'}),
                  },
                },
              ],
            }),
          ),
          200,
        );
      }),
    );
  });

  testWidgets('revision form scrolls on a phone when the keyboard is open', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showSubtitleRevision(
                context,
                videoId: 'A',
                language: 'en',
                initialIndex: 0,
                currentCues: () => [
                  const Cue(start: 1, end: 2, text: 'old', source: 'original'),
                ],
                onApply: (_) async {},
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Tạo bản dịch mới'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
