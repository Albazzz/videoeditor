import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:video/screens/browser_screen.dart';

// Exercise the real browser widget and callbacks without launching a native
// browser or depending on external websites.
class FakeBrowserPlatform extends InAppWebViewPlatform {
  final views = <FakeWebView>[];

  @override
  PlatformInAppWebViewWidget createPlatformInAppWebViewWidget(
    PlatformInAppWebViewWidgetCreationParams params,
  ) {
    final view = FakeWebView(params, views.length);
    views.add(view);
    return view;
  }
}

class FakeWebView extends PlatformInAppWebViewWidget {
  FakeWebView(super.params, int id) : super.implementation() {
    controller = FakeWebController(
      PlatformInAppWebViewControllerCreationParams(id: id),
      params,
    );
  }

  late final FakeWebController controller;
  bool initialized = false;
  bool disposed = false;

  @override
  Widget build(BuildContext context) {
    if (!initialized) {
      initialized = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        params.onWebViewCreated?.call(controller.facade);
        controller.visit(
          params.initialUrlRequest?.url?.toString() ?? 'about:blank',
          'Tab ${controller.id}',
        );
      });
    }
    return const ColoredBox(color: Colors.black);
  }

  @override
  T controllerFromPlatform<T>(PlatformInAppWebViewController controller) =>
      params.controllerFromPlatform!(controller) as T;

  @override
  void dispose() {
    disposed = true;
  }
}

class FakeWebController extends PlatformInAppWebViewController {
  FakeWebController(super.params, this.events) : super.implementation();
  final PlatformInAppWebViewWidgetCreationParams events;
  late final facade = InAppWebViewController.fromPlatform(platform: this);
  final handlers = <String, JavaScriptHandlerCallback>{};
  final scripts = <String>[];
  final entries = <WebHistoryItem>[];
  int index = -1;
  WebHistoryItem? jumpedTo;

  void visit(String url, String title) {
    events.onLoadStart?.call(facade, WebUri(url));
    if (index + 1 < entries.length) {
      entries.removeRange(index + 1, entries.length);
    }
    entries.add(
      WebHistoryItem(url: WebUri(url), title: title, index: entries.length),
    );
    index = entries.length - 1;
    events.onUpdateVisitedHistory?.call(facade, WebUri(url), false);
    events.onTitleChanged?.call(facade, title);
    events.onLoadStop?.call(facade, WebUri(url));
  }

  void reportVideo() => handlers['vsub']!([
    {
      'src': 'https://cdn.example/video.mp4',
      't': 1,
      'dur': 30,
      'page': entries[index].url.toString(),
      'area': 100000,
      'paused': true,
    },
  ]);

  @override
  Future<WebUri?> getUrl() async => entries[index].url;
  @override
  Future<String?> getTitle() async => entries[index].title;
  @override
  Future<WebHistory?> getCopyBackForwardList() async => WebHistory(
    currentIndex: index,
    list: [
      for (var i = 0; i < entries.length; i++)
        WebHistoryItem(
          url: entries[i].url,
          title: entries[i].title,
          index: i,
          offset: i - index,
        ),
    ],
  );
  @override
  Future<void> goTo({required WebHistoryItem historyItem}) async {
    jumpedTo = historyItem;
    index = historyItem.index!;
    events.onUpdateVisitedHistory?.call(facade, entries[index].url, false);
  }

  @override
  Future<void> goBack() async {
    if (index > 0) await goTo(historyItem: entries[index - 1]);
  }

  @override
  Future<void> goForward() async {
    if (index < entries.length - 1) await goTo(historyItem: entries[index + 1]);
  }

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required JavaScriptHandlerCallback callback,
  }) {
    handlers[handlerName] = callback;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    ContentWorld? contentWorld,
  }) async {
    scripts.add(source);
    return null;
  }
}

void main() {
  late FakeBrowserPlatform platform;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    platform = FakeBrowserPlatform();
    InAppWebViewPlatform.instance = platform;
  });

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: BrowserScreen())),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'switching tabs preserves WebViews; closing one disposes only that tab',
    (tester) async {
      await open(tester);
      final first = platform.views.single;
      first.controller.visit('https://a.example/', 'Trang A');
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Các tab đang mở'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Tab mới'));
      await tester.pumpAndSettle();
      expect(platform.views.length, 2);
      final second = platform.views.last;
      expect(first.disposed, false);
      expect(
        first.controller.scripts.any((s) => s.contains('"value":true')),
        true,
      );
      await tester.tap(find.byTooltip('Các tab đang mở'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trang A'));
      await tester.pumpAndSettle();
      expect(
        platform.views.length,
        2,
        reason: 'switching must not recreate either native view',
      );
      expect(
        first.controller.entries[first.controller.index].url.toString(),
        'https://a.example/',
      );
      expect(first.controller.scripts.last, contains('"value":false'));
      await tester.tap(find.byTooltip('Các tab đang mở'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Đóng tab Tab 1'));
      await tester.pumpAndSettle();
      expect(second.disposed, true);
      expect(first.disposed, false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('history jumps to native entries and retains the forward stack', (
    tester,
  ) async {
    await open(tester);
    final controller = platform.views.single.controller;
    for (final name in ['A', 'B', 'C']) {
      controller.visit('https://site.example/$name', 'Trang $name');
    }
    await controller.goBack();
    await tester.pumpAndSettle();
    await tester.longPress(find.byIcon(Icons.arrow_back_ios_new));
    await tester.pumpAndSettle();
    expect(find.text('Hiện tại'), findsOneWidget);
    expect(find.text('Trang A'), findsOneWidget);
    expect(find.text('Trang C'), findsOneWidget);
    await tester.tap(find.text('Trang C'));
    await tester.pumpAndSettle();
    expect(controller.jumpedTo?.offset, 1);
    expect(controller.index, 3);
    expect(controller.entries.length, 4);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'same-site new windows get their own tab; other sites and ads are stopped',
    (tester) async {
      await open(tester);
      final first = platform.views.single;
      first.controller.visit('https://phim.example/xem/1', 'Phim');
      await tester.pumpAndSettle();
      // Pop-unders fire on the tap that starts the film: another site's
      // window is stopped even with a gesture (the app offers "Vẫn mở").
      final otherSite = CreateWindowAction(
        windowId: 11,
        request: URLRequest(url: WebUri('https://article.example/')),
        isForMainFrame: true,
        hasGesture: true,
      );
      expect(
        await first.params.onCreateWindow!(first.controller.facade, otherSite),
        false,
      );
      await tester.pumpAndSettle();
      expect(platform.views.length, 1);
      expect(find.text('Vẫn mở'), findsOneWidget);
      final ad = CreateWindowAction(
        windowId: 9,
        request: URLRequest(url: WebUri('https://doubleclick.net/ad')),
        isForMainFrame: true,
        hasGesture: true,
      );
      expect(
        await first.params.onCreateWindow!(first.controller.facade, ad),
        false,
      );
      expect(platform.views.length, 1);
      final link = CreateWindowAction(
        windowId: 10,
        request: URLRequest(url: WebUri('https://phim.example/xem/2')),
        isForMainFrame: true,
        hasGesture: true,
      );
      expect(
        await first.params.onCreateWindow!(first.controller.facade, link),
        true,
      );
      await tester.pumpAndSettle();
      expect(platform.views.length, 2);
      expect(platform.views.last.params.windowId, 10);
      expect(platform.views.last.params.initialUrlRequest, isNull);
      expect(first.disposed, false);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('closing the final tab opens a fresh home tab', (tester) async {
    await open(tester);
    final first = platform.views.single;
    await tester.tap(find.byTooltip('Các tab đang mở'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Đóng tab Tab 0'));
    await tester.pumpAndSettle();
    expect(first.disposed, true);
    expect(platform.views.length, 2);
    expect(
      platform.views.last.params.initialUrlRequest?.url.toString(),
      kHomePage,
    );
    expect(find.text('1 tab đang mở'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('video controls can be hidden and restored without reloading', (
    tester,
  ) async {
    await open(tester);
    final controller = platform.views.single.controller;
    controller.reportVideo();
    await tester.pumpAndSettle();
    expect(find.textContaining('Đã thấy video'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đã thấy video'), findsNothing);
    await tester.tap(find.byIcon(Icons.video_settings));
    await tester.pumpAndSettle();
    expect(find.textContaining('Đã thấy video'), findsOneWidget);
    expect(controller.entries.length, 1);
    expect(platform.views.length, 1);
    await tester.pumpWidget(const SizedBox());
  });
}
