import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/background_subtitles.dart';
import 'package:video/widgets/background_subtitles_bar.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('anonymous bar opens the library and can dismiss finished work', (
    tester,
  ) async {
    final progress = BackgroundSubtitles.instance;
    progress.dismiss();
    final first = Object(), second = Object();
    progress.begin(first);
    progress.begin(second);
    progress.finish(first);
    var opened = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BackgroundSubtitlesBar(onOpen: () => opened = true),
        ),
      ),
    );
    expect(find.text('Sub: 1/2 hoàn thành'), findsOneWidget);
    await tester.tap(find.text('Sub: 1/2 hoàn thành'));
    await tester.pump();
    expect(opened, true);
    progress.finish(second);
    await tester.pumpAndSettle();
    expect(find.text('Sub: 2/2 hoàn thành'), findsOneWidget);
    await tester.tap(find.byTooltip('Ẩn tiến trình đã xong'));
    await tester.pumpAndSettle();
    expect(find.text('Sub: 2/2 hoàn thành'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'native progress contains counts only and completes a whole batch',
    () async {
      const channel = MethodChannel('test/subtitle_counts');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final progress = BackgroundSubtitles(channel: channel, enabled: true);
      progress.begin('private film title');
      progress.begin('https://private.example/another-video');
      progress.update('private film title', active: true, fraction: 0.8);
      progress.finish('private film title');
      expect(progress.state.value.label, 'Sub: 1/2 hoàn thành');
      expect(progress.state.value.active, true);
      expect(progress.state.value.progress, 5000);
      progress.finish('https://private.example/another-video');
      await progress.flush();
      expect(progress.state.value.label, 'Sub: 2/2 hoàn thành');
      expect(progress.state.value.active, false);
      expect(progress.state.value.canDismiss, true);
      expect(progress.state.value.progress, 10000);
      for (final call in calls) {
        expect(call.method, 'update');
        final payload = call.arguments as Map;
        expect(
          payload.keys,
          unorderedEquals(['completed', 'total', 'active', 'progress']),
        );
        expect(payload.values.every((v) => v is int || v is bool), true);
      }
      progress.begin('new batch');
      expect(progress.state.value.label, 'Sub: 0/1 hoàn thành');
      progress.cancel('new batch');
      progress.dismiss();
      await progress.flush();
      expect(progress.state.value.total, 0);
    },
  );

  test('cancelled and failed videos never count as completed', () {
    final progress = BackgroundSubtitles(enabled: false);
    final a = Object(), b = Object();
    progress.begin(a);
    progress.begin(b);
    progress.finish(a);
    progress.update(b, active: false, fraction: .7);
    progress.dismiss();
    expect(progress.state.value.total, 2);
    expect(progress.state.value.canDismiss, false);
    progress.cancel(b);
    expect(progress.state.value.label, 'Sub: 1/2 hoàn thành');
    expect(progress.state.value.active, false);
    expect(progress.state.value.canDismiss, true);
    progress.finish(
      b,
    ); // A late callback after cancellation cannot claim success.
    expect(progress.state.value.completed, 1);
    progress.begin(Object());
    expect(progress.state.value.label, 'Sub: 0/1 hoàn thành');
  });
}
