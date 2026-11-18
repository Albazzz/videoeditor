import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/app_log.dart';
import 'package:video/services/keep_awake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the log never keeps tokens, keys or cookies', () {
    final dirty = AppLog.sanitize(
      'ClientException: Connection closed, uri=https://tp4.example.cn/v/120.ts'
      '?auth_key=1794821146-065-ea5adbc2 key sk-or-v1-0123456789abcdef '
      'Bearer abc.def-123 hash=wdmn0Qnr&expires=1794907343 ok',
    );
    expect(dirty, isNot(contains('auth_key=1794')));
    expect(dirty, isNot(contains('abc.def-123')));
    expect(dirty, isNot(contains('0123456789abcdef')));
    expect(dirty, isNot(contains('wdmn0Qnr')));
    expect(dirty, contains('https://tp4.example.cn/v/120.ts?…'));
    expect(dirty, endsWith('ok'));

    // After a cookie/authorization header the rest of the line goes: its
    // value has spaces, so where it ends cannot be told safely.
    final header = AppLog.sanitize('sent cookie: session=xyz; a=b to cdn');
    expect(header, 'sent cookie: ***');
    // Ordinary text is left alone.
    expect(AppLog.sanitize('Nghe tới 12:30 · 5 câu'), 'Nghe tới 12:30 · 5 câu');
  });

  test('the screen stays on while any screen still works', () {
    final browser = Object();
    final player = Object();
    KeepAwake.hold(browser, true);
    KeepAwake.hold(player, true);
    KeepAwake.hold(player, false);
    expect(KeepAwake.isOn, isTrue, reason: 'the browser still works');
    KeepAwake.hold(browser, false);
    expect(KeepAwake.isOn, isFalse);
  });
}
