import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:video/screens/lock_screen.dart';

void main() {
  testWidgets('key field above the navigator can be tapped and typed in', (
    tester,
  ) async {
    final errors = <FlutterErrorDetails>[];
    final previous = FlutterError.onError;
    FlutterError.onError = errors.add;
    addTearDown(() => FlutterError.onError = previous);

    // Same arrangement as main.dart: the lock sits in MaterialApp.builder.
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Stack(
          children: [
            ?child,
            LockScreen(setup: false, onUnlocked: () {}),
          ],
        ),
        home: const Scaffold(),
      ),
    );
    final field = find.byType(TextField).first;
    await tester.tap(field);
    await tester.pump();
    await tester.enterText(field, 'abc');
    await tester.pump();
    await tester.tap(field);
    await tester.pump(const Duration(milliseconds: 600));

    expect(errors, isEmpty, reason: errors.map((e) => e.exception).join('\n'));
  });
}
