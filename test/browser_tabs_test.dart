import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/browser_tabs.dart';
import 'package:video/services/active_work.dart';
import 'package:video/services/subtitle_session.dart';

void main() {
  test('closing work in one tab preserves work belonging to other tabs', () {
    final first = SubtitleSession(input: 'first.mp4', language: 'ja');
    final second = SubtitleSession(input: 'second.mp4', language: 'ja');
    ActiveWork.begin('first', 'First', first);
    ActiveWork.begin('second', 'Second', second);
    ActiveWork.end(second);
    expect(ActiveWork.current.value?.session, same(first));
    ActiveWork.begin('second', 'Second', second);
    ActiveWork.end(first);
    expect(ActiveWork.current.value?.session, same(second));
    ActiveWork.end(second);
    expect(ActiveWork.current.value, isNull);
    first.dispose();
    second.dispose();
  });
  test(
    'tabs retain identity and navigation metadata when selected or reordered',
    () {
      final tabs = BrowserTabs(homeUrl: 'https://home.example/');
      addTearDown(tabs.dispose);
      final first = tabs.selected;
      tabs.update(
        first.id,
        url: 'https://a.example/page',
        title: 'Trang A',
        canGoBack: true,
      );
      final second = tabs.add(url: 'https://b.example/', windowId: 42);
      expect(second.windowId, 42);
      expect(tabs.selected, same(second));
      tabs.select(first.id);
      expect(tabs.selected, same(first));
      expect(first.label, 'Trang A');
      expect(first.canGoBack, isTrue);
      tabs.close(second.id);
      expect(tabs.selected, same(first));
      expect(tabs.selected.url, 'https://a.example/page');
      tabs.update(second.id, title: 'Late callback from closed tab');
      expect(tabs.tabs.length, 1);
    },
  );

  test(
    'closing the selected tab chooses a neighbour; closing the last opens home',
    () {
      final tabs = BrowserTabs(homeUrl: 'https://home.example/');
      addTearDown(tabs.dispose);
      final first = tabs.selected;
      final middle = tabs.add();
      final last = tabs.add();
      tabs.select(middle.id);
      tabs.close(middle.id);
      expect(tabs.selected, same(last));
      tabs.close(last.id);
      expect(tabs.selected, same(first));
      tabs.close(first.id);
      expect(tabs.tabs.length, 1);
      expect(tabs.selected.id, isNot(first.id));
      expect(tabs.selected.url, tabs.homeUrl);
    },
  );
}
