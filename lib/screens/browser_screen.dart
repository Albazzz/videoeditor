import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/ad_block.dart';
import '../services/active_work.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/bookmarks.dart';
import '../services/browser_tabs.dart';
import '../services/open_page.dart';
import '../services/subtitle_session.dart';
import '../services/keep_awake.dart';
import '../services/subtitle_store.dart';
import '../services/watch_position.dart';
import '../services/web_video.dart';
import '../widgets/activity_icon.dart';
import '../widgets/bookmarks_sheet.dart';
import '../widgets/browser_history_sheet.dart';
import '../widgets/browser_tabs_sheet.dart';
import '../widgets/common.dart';
import '../widgets/subtitle_details.dart';
import '../widgets/subtitle_import.dart';
import '../widgets/subtitle_picker.dart';
import '../widgets/session_progress.dart';
import '../widgets/subtitle_style.dart';
import '../widgets/subtitle_revision.dart';
import '../widgets/video_language.dart';
import 'retained_audio_screen.dart';
import 'player_screen.dart';

const kHomePage = 'https://www.google.com/';

/// A browser that adds live Vietnamese subtitles to whatever video the page
/// is playing.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _tabs = BrowserTabs(homeUrl: kHomePage);
  final _pages = <int, GlobalKey<_BrowserTabViewState>>{};
  bool _disposing = false;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_changed);
    openPageRequest.addListener(_openRequested);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  void _openRequested() {
    final url = openPageRequest.value;
    if (url == null || url.isEmpty) return;
    final existing = _tabs.tabs.where((t) => t.url == url).firstOrNull;
    if (existing != null) {
      _tabs.select(existing.id);
    } else {
      _newTab(url: url);
    }
  }

  void _newTab({String? url, int? windowId, bool select = true}) {
    if (_disposing) return;
    final tab = _tabs.add(url: url, windowId: windowId, select: select);
    if (!select) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: const Text('Đã mở trong tab mới'),
            action: SnackBarAction(
              label: 'Xem',
              onPressed: () {
                if (mounted && !_disposing) _tabs.select(tab.id);
              },
            ),
          ),
        );
    }
  }

  void _closeTab(int id) {
    if (_disposing) return;
    _tabs.close(id);
    _pages.remove(id);
  }

  void _showTabs() {
    showBrowserTabs(
      context,
      _tabs,
      onNewTab: () => _newTab(),
      onClose: _closeTab,
    );
  }

  void _updateWork() {
    if (_disposing) return;
    KeepAwake.hold(
      this,
      _pages.values.any((key) => KeepAwake.needed(key.currentState?._session)),
    );
  }

  @override
  void dispose() {
    _disposing = true;
    openPageRequest.removeListener(_openRequested);
    _tabs.dispose();
    KeepAwake.hold(this, false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_tabs.selected.canGoBack && _tabs.tabs.length == 1,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        final tab = _tabs.selected;
        if (tab.canGoBack) {
          await _pages[tab.id]?.currentState?._web?.goBack();
        } else if (_tabs.tabs.length > 1) {
          _closeTab(tab.id);
        }
      },
      child: IndexedStack(
        index: _tabs.selectedIndex,
        children: [
          for (final tab in _tabs.tabs)
            _BrowserTabView(
              key: _pages.putIfAbsent(
                tab.id,
                () => GlobalKey<_BrowserTabViewState>(),
              ),
              tab: tab,
              active: tab.id == _tabs.selected.id,
              tabCount: _tabs.tabs.length,
              onTabs: _showTabs,
              onNewTab: _newTab,
              onClose: () => _closeTab(tab.id),
              onPage: ({url, title, canGoBack}) {
                if (_disposing) return;
                _tabs.update(
                  tab.id,
                  url: url,
                  title: title,
                  canGoBack: canGoBack,
                );
              },
              onWork: _updateWork,
            ),
        ],
      ),
    );
  }
}

class _BrowserTabView extends StatefulWidget {
  const _BrowserTabView({
    super.key,
    required this.tab,
    required this.active,
    required this.tabCount,
    required this.onTabs,
    required this.onNewTab,
    required this.onClose,
    required this.onPage,
    required this.onWork,
  });

  final BrowserTab tab;
  final bool active;
  final int tabCount;
  final VoidCallback onTabs;
  final void Function({String? url, int? windowId, bool select}) onNewTab;
  final VoidCallback onClose;
  final void Function({String? url, String? title, bool? canGoBack}) onPage;
  final VoidCallback onWork;

  @override
  State<_BrowserTabView> createState() => _BrowserTabViewState();
}

class _BrowserTabViewState extends State<_BrowserTabView> {
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  InAppWebViewController? _web;
  double _loading = 0;
  bool _canBack = false;
  bool _canForward = false;
  bool _panelHidden = false;
  bool _appliedAdBlock = appSettings.adBlock;
  int _historyRequest = 0;
  DateTime _lastBackgroundPause = DateTime(0);

  WebVideo? _video;
  DateTime _lastReport = DateTime(0);
  SubtitleSession? _session;
  SessionSaver? _saver;
  String _sessionSrc = '';
  String _selectedVideoKey = '';
  String _fileSource = '';
  final _sentCues = <(double, String), (double, String)>{};
  String _notifiedLanguage = '';

  /// The page is playing a different video (an advert, the next
  /// episode) from the one subtitles are being made for.
  bool _otherVideo = false;
  DateTime _lastResend = DateTime(0);

  /// Lines read from a subtitle file for this page, shown instead of a
  /// recognition session.
  List<Cue>? _fileCues;
  String _filePage = '';
  String _fileLanguage = '';
  double _fileOffset = 0;

  /// The lines on show came from a file (not made earlier by the app).
  bool _fileImported = false;

  /// Lines on show were made earlier but do not cover the whole film.
  bool _canCarryOn = false;

  /// Subtitles are kept but not drawn (CC switched off).
  bool _hidden = false;

  /// The page has confirmed it holds the lines sent (logged once).
  bool _ackLogged = false;

  /// Top-level page address, kept in step with navigation.
  String _pageUrl = '';

  /// Page already checked for saved subtitles and a resume point.
  String _autoPage = '';
  (String, String)? _shortVideoChecked;
  bool _autoBusy = false;
  DateTime _lastPositionSave = DateTime(0);

  /// Latest report of every video on the page (adverts included).
  final _seen = <String, (WebVideo, DateTime)>{};

  /// Videos already written to the log for this page.
  final _logged = <String>{};

  /// The page on show is among the saved pages.
  bool _bookmarked = false;

  Future<void> _checkBookmark() async {
    final url = _pageUrl;
    final saved = url.isNotEmpty && await Bookmarks.contains(url);
    if (mounted && url == _pageUrl && saved != _bookmarked) {
      setState(() => _bookmarked = saved);
    }
  }

  /// A small picture of a page with subtitles, for the subtitle store
  /// (shared with saved pages; taken once per page).
  Future<void> _keepPagePicture(String page) async {
    if (!page.startsWith('http')) return;
    try {
      final dir = await Bookmarks.thumbDir();
      if (dir == null ||
          File(p.join(dir.path, Bookmarks.thumbName(page))).existsSync()) {
        return;
      }
      final shot = await _web?.takeScreenshot(
        screenshotConfiguration: ScreenshotConfiguration(
          compressFormat: CompressFormat.JPEG,
          quality: 60,
          snapshotWidth: 320,
        ),
      );
      if (shot != null) await Bookmarks.saveThumb(page, shot);
    } catch (e) {
      AppLog.e('web', 'Không chụp được ảnh trang: $e');
    }
  }

  Future<void> _toggleBookmark() async {
    final (page, title) = await _pageInfo();
    if (!mounted || !page.startsWith('http')) return;
    if (_bookmarked) {
      await Bookmarks.remove(page);
      if (mounted) toast(context, 'Đã bỏ lưu trang');
    } else {
      // Ask where it goes; nothing is filed away without the user's say.
      final place = await askBookmarkPlace(context, title);
      if (place == null || !mounted) return;
      final (name, folder) = place;
      // A small picture of the page for the saved-pages list.
      var thumb = '';
      try {
        final shot = await _web?.takeScreenshot(
          screenshotConfiguration: ScreenshotConfiguration(
            compressFormat: CompressFormat.JPEG,
            quality: 60,
            snapshotWidth: 320,
          ),
        );
        if (shot != null) thumb = await Bookmarks.saveThumb(page, shot);
      } catch (e) {
        AppLog.e('web', 'Không chụp được ảnh trang: $e');
      }
      final bookmark = await Bookmarks.add(
        page,
        name.isEmpty ? title : name,
        folder: folder,
        thumb: thumb,
      );
      if (mounted) {
        toast(
          context,
          'Đã lưu vào ${bookmark.folder.isEmpty ? 'Ngoài cùng' : bookmark.folder}',
        );
      }
    }
    await _checkBookmark();
  }

  Future<void> _openBookmarks() async {
    final url = await showBookmarks(context);
    if (!mounted) return;
    await _checkBookmark();
    if (url == null || !mounted) return;
    _address.text = url;
    _go(url);
  }

  double _speed = 1;
  DateTime _lastBlockNotice = DateTime(0);

  /// Built once: the web view only reads them when it is created.
  late final _settings = InAppWebViewSettings(
    allowsInlineMediaPlayback: true,
    mediaPlaybackRequiresUserGesture: false,
    allowsBackForwardNavigationGestures: true,
    javaScriptCanOpenWindowsAutomatically: false,
    supportMultipleWindows: true,
    // Pass as Safari: some sites stall or loop on a "checking your
    // browser" page for an unknown web view.
    applicationNameForUserAgent: _safariName(),
    // No per-navigation callback into Dart: it made every page and every
    // iframe wait on the app. Ad hosts are blocked by the content blocker.
    contentBlockers: appSettings.adBlock ? adBlockRules() : [],
  );
  late final _scripts = UnmodifiableListView(_userScripts());

  /// The tail Mobile Safari adds to its user agent, for this iOS version.
  static String _safariName() {
    final m = RegExp(
      r'(\d+)\.(\d+)',
    ).firstMatch(Platform.operatingSystemVersion);
    final version = m == null ? '18.0' : '${m[1]}.${m[2]}';
    return 'Version/$version Mobile/15E148 Safari/604.1';
  }

  DateTime _loadStarted = DateTime(0);
  Timer? _slowLoad;

  void _onLoadStart(String url) {
    _selectedVideoKey = '';
    _autoPage = '';
    _shortVideoChecked = null;
    _seen.clear();
    _logged.clear();
    _loadStarted = DateTime.now();
    if (url.isNotEmpty && url != 'about:blank') _pageUrl = url;
    AppLog.i('web', 'Mở ${AppLog.url(url)}');
    _slowLoad?.cancel();
    _slowLoad = Timer(const Duration(seconds: 15), () {
      if (!mounted || !widget.active || _loading >= 1) return;
      AppLog.i(
        'web',
        'Trang tải quá 15 giây (${(_loading * 100).round()}%), '
            'chặn quảng cáo: ${appSettings.adBlock ? 'bật' : 'tắt'}',
      );
      if (!appSettings.adBlock) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 6),
          content: const Text('Trang tải lâu. Thử tắt chặn quảng cáo?'),
          action: SnackBarAction(label: 'Tắt', onPressed: _toggleAdBlock),
        ),
      );
    });
  }

  void _onLoadStop(String url) {
    _slowLoad?.cancel();
    final ms = DateTime.now().difference(_loadStarted).inMilliseconds;
    AppLog.i('web', 'Tải xong sau ${(ms / 1000).toStringAsFixed(1)} giây');
  }

  List<UserScript> _userScripts() => [
    UserScript(
      source: kPageScript,
      injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
      forMainFrameOnly: false,
    ),
    if (appSettings.adBlock)
      UserScript(
        source: kAdBlockScript,
        injectionTime: UserScriptInjectionTime.AT_DOCUMENT_START,
        forMainFrameOnly: false,
      ),
  ];

  Future<void> _toggleAdBlock() async {
    final on = !appSettings.adBlock;
    _appliedAdBlock = on;
    appSettings.setAdBlock(on);
    setState(() {});
    final web = _web;
    if (web != null) {
      await web.removeAllUserScripts();
      await web.addUserScripts(userScripts: _userScripts());
      // The full settings: a fresh object would reset the others to their
      // defaults (inline playback off, for one).
      _settings.contentBlockers = on ? adBlockRules() : [];
      await web.setSettings(settings: _settings);
      await web.reload();
    }
    if (mounted) {
      toast(context, on ? 'Đã bật chặn quảng cáo' : 'Đã tắt chặn quảng cáo');
    }
  }

  bool _openWindow(URLRequest request, {int? windowId}) {
    final target = request.url;
    if (target == null || !{'https', 'http'}.contains(target.scheme)) {
      return false;
    }
    final url = target.toString();
    if (!mounted || !widget.active) return false;
    if (appSettings.backgroundLinks) {
      widget.onNewTab(url: url, windowId: windowId, select: false);
      return windowId != null;
    }
    _web?.loadUrl(urlRequest: request);
    return false;
  }

  void _onBlocked(String url) {
    if (!mounted || !widget.active) return;
    final now = DateTime.now();
    if (now.difference(_lastBlockNotice) < const Duration(seconds: 2)) return;
    _lastBlockNotice = now;
    final target = Uri.tryParse(url);
    final canOpen =
        target != null &&
        {'https', 'http'}.contains(target.scheme) &&
        !isAdHost(target.host);
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 3),
          content: Text(
            canOpen
                ? 'Đã chặn cửa sổ mới: ${target.host}'
                : 'Đã chặn một quảng cáo',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          action: canOpen
              ? SnackBarAction(
                  label: 'Vẫn mở',
                  onPressed: () => _openWindow(URLRequest(url: WebUri(url))),
                )
              : null,
        ),
      );
  }

  @override
  void initState() {
    super.initState();
    _pageUrl = widget.tab.initialUrl;
    _address.text = _pageUrl;
    appSettings.addListener(_onSettings);
    ActiveWork.all.addListener(_onWorks);
  }

  /// Work started, stopped or finished somewhere (the subtitle store, the
  /// player): let go of a stopped session and refresh the "being made" bar.
  void _onWorks() {
    final session = _session;
    if (session != null && ActiveWork.wasStopped(session)) _onWorkStopped();
    if (mounted) setState(() {});
  }

  /// The session shown here was stopped elsewhere: keep its lines on the
  /// page with ▶ to carry on, without touching the disposed session.
  void _onWorkStopped() {
    final session = _session;
    if (session == null) return;
    final cues = List.of(session.cues);
    final language = session.language;
    session.removeListener(_onSession);
    _session = null;
    _saver = null;
    _sessionSrc = '';
    _send({'__vsub': 'clear'});
    if (!mounted) return;
    if (cues.isNotEmpty) {
      _showFileCues(cues, _pageUrl, language, imported: false);
      setState(() => _canCarryOn = _video?.playable ?? false);
    }
  }

  @override
  void didUpdateWidget(covariant _BrowserTabView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active && !widget.active) {
      _addressFocus.unfocus();
      _pauseBackground();
      // Off screen: its work becomes background and gives way.
      _session?.foreground = false;
    } else if (!oldWidget.active && widget.active) {
      _checkBookmark();
      _web?.evaluateJavascript(
        source:
            'window.__vsubSend && window.__vsubSend({"__vsub":"background","value":false});',
      );
      _refreshHistory();
    }
  }

  void _pauseBackground() {
    _lastBackgroundPause = DateTime.now();
    // Pause all frames, including players the app has not selected yet.
    _web?.evaluateJavascript(
      source:
          'window.__vsubSend && window.__vsubSend({"__vsub":"background","value":true});',
    );
  }

  Future<void> _refreshHistory() async {
    final request = ++_historyRequest;
    WebHistory? history;
    try {
      history = await _web?.getCopyBackForwardList();
    } catch (e) {
      if (mounted) AppLog.i('web', 'Chưa đọc được lịch sử tab: $e');
      return;
    }
    if (!mounted || request != _historyRequest || history == null) return;
    final index = history.currentIndex ?? 0;
    final count = history.list?.length ?? 0;
    setState(() {
      _canBack = index > 0;
      _canForward = index < count - 1;
    });
    widget.onPage(canGoBack: _canBack);
  }

  Future<void> _showHistory() async {
    final web = _web;
    final history = await web?.getCopyBackForwardList();
    if (!mounted || !widget.active || web == null) return;
    final item = await showBrowserHistory(context, history ?? WebHistory());
    if (item == null || !mounted || !widget.active) return;
    await web.goTo(historyItem: item);
    await _refreshHistory();
  }

  SubtitleMode get _mode =>
      appSettings.subWhole ? SubtitleMode.whole : SubtitleMode.follow;

  /// Style changes show at once on the page.
  void _onSettings() {
    if (_appliedAdBlock != appSettings.adBlock) {
      _appliedAdBlock = appSettings.adBlock;
      unawaited(_syncAdBlock());
    }
    _session?.mode = _mode;
    _session?.parallel = appSettings.parallelSubtitles;
    if (_session != null || _fileCues != null) {
      _send(appSettings.subtitleOpts);
    }
    if (mounted) setState(() {});
  }

  Future<void> _syncAdBlock() async {
    final web = _web;
    if (web == null) return;
    try {
      await web.removeAllUserScripts();
      if (!mounted) return;
      await web.addUserScripts(userScripts: _userScripts());
      _settings.contentBlockers = appSettings.adBlock ? adBlockRules() : [];
      await web.setSettings(settings: _settings);
    } catch (e) {
      if (mounted) {
        AppLog.e('web', 'Không cập nhật được chặn quảng cáo cho tab: $e');
      }
    }
  }

  @override
  void dispose() {
    appSettings.removeListener(_onSettings);
    ActiveWork.all.removeListener(_onWorks);
    _slowLoad?.cancel();
    _session?.removeListener(_onSession);
    _session?.mode = SubtitleMode.whole;
    _saver?.save();
    _session = null;
    widget.onWork();
    _address.dispose();
    _addressFocus.dispose();
    super.dispose();
  }

  void _go(String input) {
    var text = input.trim();
    if (text.isEmpty) return;
    if (!text.contains('://')) {
      text = text.contains('.') && !text.contains(' ')
          ? 'https://$text'
          : 'https://www.google.com/search?q=${Uri.encodeQueryComponent(text)}';
    }
    FocusScope.of(context).unfocus();
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri(text)));
  }

  /// Sends a command to the page. Only the frame holding the chosen video
  /// acts on it (clearing goes to all), so adverts get no subtitles.
  void _send(Map<String, Object?> message) {
    final target = _session != null ? _sessionSrc : _video?.src;
    final full = message['__vsub'] == 'clear' || target == null
        ? message
        : {
            ...message,
            'target': target,
            if (_video?.elementId.isNotEmpty == true)
              'element': _video!.elementId,
          };
    _web?.evaluateJavascript(
      source: 'window.__vsubSend && window.__vsubSend(${jsonEncode(full)});',
    );
  }

  void _onReport(Object? message) {
    if (!widget.active) {
      if (DateTime.now().difference(_lastBackgroundPause) >
          const Duration(seconds: 1)) {
        _pauseBackground();
      }
      return;
    }
    final wasVisible = _videoVisible;
    final report = WebVideo.fromMessage(message);
    if (report == null || !mounted) return;
    // Every frame with a video reports; adverts too. Keep the latest of
    // each and follow only the one that looks like the film.
    final now = DateTime.now();
    _seen.removeWhere(
      (_, entry) =>
          report.elementId.isNotEmpty &&
          entry.$1.elementId == report.elementId &&
          entry.$1.src != report.src,
    );
    _seen[report.reportKey] = (report, now);
    _seen.removeWhere(
      (_, e) => now.difference(e.$2) > const Duration(milliseconds: 2500),
    );
    final video = WebVideo.main(
      _seen.values.map((e) => e.$1),
      keep: _selectedVideoKey,
    );
    if (video == null || video.reportKey != report.reportKey) return;
    _lastReport = now;
    final changed = _video?.reportKey != video.reportKey;
    if (changed &&
        (_session != null || _fileCues != null) &&
        (_session?.input ?? _fileSource) != video.src) {
      _detachSubtitles();
      _autoPage = '';
    }
    if (changed && _logged.add(video.src)) {
      AppLog.i(
        'web',
        'Chọn video ${AppLog.url(video.src)} '
            '(${video.playable ? 'lấy được luồng' : 'luồng bị giấu'}, '
            'dài ${formatTime(video.duration)}, ${_seen.length} video trên '
            'trang) trên ${AppLog.url(video.page)}',
      );
    }
    _video = video;
    final fileCues = _fileCues;
    final want = _session?.cues.length ?? fileCues?.length ?? 0;
    if (!_ackLogged && want > 0 && !_hidden && video.cueCount >= want) {
      _ackLogged = true;
      AppLog.i('web', 'Trang đã nhận ${video.cueCount} dòng phụ đề');
    }
    if (fileCues != null &&
        !_hidden &&
        video.cueCount < fileCues.length &&
        DateTime.now().difference(_lastResend) > const Duration(seconds: 1)) {
      _lastResend = DateTime.now();
      _sendAllCues(fileCues);
    }
    final session = _session;
    if (session != null) {
      // Adverts often play in their own <video> first; keep the session
      // and simply wait until the main video is back.
      // Another address is only another video if the length differs too:
      // the same film often gets a new signed link (or another quality).
      final sameFilm =
          video.src == _sessionSrc ||
          (session.duration > 0 &&
              video.duration > 0 &&
              (session.duration - video.duration).abs() <= 5);
      final other = !sameFilm;
      if (other != _otherVideo) setState(() => _otherVideo = other);
      if (!other && video.src != _sessionSrc) {
        _sessionSrc = video.src;
        session.updateSource(video.src);
      }
      // On screen in the active tab: this film's stretch ahead comes first.
      session.foreground = widget.active && !other;
      if (!other) {
        session.updatePosition(video.time, duration: video.duration);
        // The player frame was reloaded and lost its lines: send them again.
        final now = DateTime.now();
        if (!_hidden &&
            video.cueCount < session.cues.length &&
            now.difference(_lastResend) > const Duration(seconds: 1)) {
          _lastResend = now;
          _sendAllCues(session.cues);
        }
      }
    }
    _rememberPosition(video);
    // "Làm tiếp" from the subtitle store: carry on once the film plays.
    if (_session == null &&
        video.playable &&
        video.duration >= WatchPosition.minDuration &&
        takeResume(_pageUrl)) {
      toast(context, 'Làm tiếp phụ đề cho phim này');
      unawaited(_startSubtitles());
    }
    final short = video.duration < WatchPosition.minDuration;
    if (_autoPage != _pageUrl &&
        !_autoBusy &&
        video.duration > 0 &&
        (!short || _shortVideoChecked != (_pageUrl, video.src))) {
      if (short) _shortVideoChecked = (_pageUrl, video.src);
      _autoForPage(video);
    }
    if (changed || !wasVisible) setState(() {});
  }

  /// The film itself, not an advert, is playing on this page: bring
  /// back its subtitles and offer to carry on where the user stopped.
  Future<void> _autoForPage(WebVideo video) async {
    final page = _pageUrl;
    if (page.isEmpty) return;
    _autoBusy = true;
    try {
      final id = SubtitleStore.idForVideo(page, video.src);
      final running = ActiveWork.findVideo(id, page, video.duration);
      if (running != null &&
          mounted &&
          page == _pageUrl &&
          _video?.src == video.src) {
        _attachWork(running, video);
        return;
      }
      final saved = await SubtitleStore.loadVideo(
        page,
        video.src,
        duration: video.duration,
      );
      final resume = await WatchPosition.load(
        SubtitleStore.idFor(page),
        duration: video.duration,
      );
      if (!mounted ||
          !widget.active ||
          page != _pageUrl ||
          _video?.src != video.src) {
        return;
      }
      // A short film may have its own subtitles; a pre-roll must not use
      // the longer film's subtitles or consume its resume prompt.
      if (video.duration < WatchPosition.minDuration &&
          (saved == null ||
              saved.duration > 0 &&
                  (saved.duration - video.duration).abs() > 5)) {
        return;
      }
      _autoPage = page;
      if (resume != null && video.time < 10) _offerResume(resume);
      if (saved == null || saved.cues.isEmpty) return;
      if (_session != null || _fileCues != null) return;
      if (saved.imported) {
        AppLog.i('web', 'Tự hiện ${saved.cues.length} dòng đã nhập');
        _showFileCues(saved.cues, page, saved.language);
        toast(context, 'Đã bật phụ đề đã nhập cho phim này');
      } else {
        // Shown as they are; making more waits for the user ("Làm tiếp").
        if (!mounted) return;
        AppLog.i('web', 'Tự hiện ${saved.cues.length} dòng đã làm');
        _showFileCues(saved.cues, page, saved.language, imported: false);
        _canCarryOn = saved.canResume && video.playable;
        toast(
          context,
          _canCarryOn
              ? 'Đã hiện phụ đề làm dở (${subtitleProgressLabel(covered: saved.covered, duration: saved.duration).toLowerCase()}). Bấm "Làm tiếp" để làm nốt'
              : 'Đã bật phụ đề đã làm trước cho phim này',
        );
      }
    } catch (e) {
      AppLog.e('web', 'Tự bật phụ đề lỗi: $e');
    } finally {
      _autoBusy = false;
    }
  }

  void _offerResume(double t) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 8),
          content: Text('Lần trước bạn xem tới ${formatTime(t)}'),
          action: SnackBarAction(
            label: 'Xem tiếp',
            onPressed: () => _send({'__vsub': 'seek', 't': t}),
          ),
        ),
      );
  }

  void _rememberPosition(WebVideo video) {
    if (_pageUrl.isEmpty || _otherVideo) return;
    final now = DateTime.now();
    if (now.difference(_lastPositionSave) < const Duration(seconds: 5)) {
      return;
    }
    _lastPositionSave = now;
    WatchPosition.save(
      SubtitleStore.idFor(_pageUrl),
      video.time,
      video.duration,
    );
  }

  static List<Object> _cueData(Cue c) => [c.start, c.end, c.text, c.source];

  /// Replaces every line the page holds; the page draws them itself.
  void _sendAllCues(List<Cue> cues) {
    _sentCues.clear();
    for (final cue in cues) {
      _sentCues[(cue.start, cue.source)] = (cue.end, cue.text);
    }
    _send(appSettings.subtitleOpts);
    _send({
      '__vsub': 'cues',
      'list': [for (final c in cues) _cueData(c)],
    });
  }

  Future<(String, String)> _pageInfo() async {
    final page = (await _web?.getUrl())?.toString() ?? _video?.page ?? '';
    final title = (await _web?.getTitle()) ?? '';
    return (page, title);
  }

  /// The same film on another site: takes subtitles saved for another
  /// page, keeps a copy for this one, and shows them or carries on.
  Future<void> _useFromLibrary() async {
    final video = _video;
    final (page, title) = await _pageInfo();
    if (!mounted || page.isEmpty) return;
    if (video == null) return;
    final id = SubtitleStore.idForVideo(page, video.src);
    final choice = await pickSavedSubtitles(
      context,
      excludeId: id,
      pageTitle: title,
      duration: video.duration,
      canCarryOn: video.playable,
    );
    if (choice == null ||
        !mounted ||
        _video?.src != video.src ||
        _pageUrl != page) {
      return;
    }
    final (src, use) = choice;
    if (_session != null || _fileCues != null) {
      // Let the current lines be written before the copy replaces them.
      final saver = _saver;
      _saver = null;
      final closing = saver?.close();
      await _stopSubtitles();
      await closing;
    }
    await SubtitleStore.save(
      SavedSubs(
        id: id,
        title: title.isEmpty ? src.title : title,
        page: page,
        source: video.src,
        language: src.language,
        updated: DateTime.now(),
        cues: src.cues,
        covered: src.covered,
        duration: src.duration,
        complete: src.complete,
        imported: src.imported,
      ),
    );
    AppLog.i(
      'web',
      'Dùng ${src.cues.length} dòng của ${AppLog.url(src.page)} '
          '(${use.name})',
    );
    if (!mounted || _pageUrl != page || _video?.src != video.src) return;
    _autoPage = page;
    if (use == PickedUse.carryOn) {
      await _startSubtitles();
    } else {
      _showFileCues(src.cues, page, src.language, imported: src.imported);
      _canCarryOn = src.canResume && video.playable;
      toast(
        context,
        'Đã dùng ${src.cues.length} dòng. Lệch giờ thì chỉnh ở ⋮ '
        '(sớm/muộn 0,5 giây)',
      );
    }
  }

  /// Reads a subtitle file for the page being watched.
  Future<void> _importForPage() async {
    final video = _video;
    if (video == null) return;
    final (page, title) = await _pageInfo();
    if (!mounted || page.isEmpty) return;
    final imported = await importSubtitleFile(context);
    if (imported == null ||
        !mounted ||
        _video?.src != video.src ||
        _pageUrl != page) {
      return;
    }
    if (_session != null) await _stopSubtitles();
    if (!mounted || _video?.src != video.src || _pageUrl != page) return;
    await SubtitleStore.save(
      SavedSubs(
        id: SubtitleStore.idForVideo(page, video.src),
        title: title.isEmpty ? imported.fileName : title,
        page: page,
        source: video.src,
        language: imported.language,
        updated: DateTime.now(),
        cues: imported.cues,
        covered: const [],
        duration: _video?.duration ?? 0,
        complete: true,
        imported: true,
      ),
    );
    if (!mounted || _pageUrl != page || _video?.src != video.src) return;
    AppLog.i(
      'web',
      'Nhập ${imported.fileName}: ${imported.cues.length} dòng, '
          'tiếng ${imported.language}',
    );
    _showFileCues(imported.cues, page, imported.language);
    toast(context, 'Đã nhập ${imported.cues.length} dòng phụ đề');
  }

  void _showFileCues(
    List<Cue> cues,
    String page,
    String language, {
    bool imported = true,
  }) {
    if (_session != null) _stopSubtitles();
    _ackLogged = false;
    setState(() {
      _canCarryOn = false;
      _hidden = false;
      _fileImported = imported;
      _fileCues = cues;
      _filePage = page;
      _fileSource = _video?.src ?? '';
      _fileLanguage = language;
      _fileOffset = 0;
    });
    _sendAllCues(cues);
  }

  /// Moves file subtitles earlier (negative) or later, and keeps the change.
  Future<void> _shiftFileCues(double seconds) async {
    final cues = _fileCues;
    if (cues == null) return;
    final shifted = shiftCues(cues, seconds);
    setState(() {
      _fileCues = shifted;
      _fileOffset += seconds;
    });
    _sendAllCues(shifted);
    final id = SubtitleStore.idForVideo(_filePage, _fileSource);
    final saved = await SubtitleStore.load(id);
    if (saved != null) await SubtitleStore.save(saved.withCues(shifted));
  }

  Future<void> _startSubtitles() async {
    final video = _video;
    AppLog.i('web', 'Bấm CC${video == null ? ' (chưa thấy video)' : ''}');
    if (video == null) return;
    final (page, title) = await _pageInfo();
    unawaited(_keepPagePicture(page));
    final id = SubtitleStore.idForVideo(page, video.src);
    final running = ActiveWork.findVideo(id, page, video.duration);
    if (running != null) {
      _attachWork(running, video);
      return;
    }
    final saved = await SubtitleStore.loadVideo(
      page,
      video.src,
      duration: video.duration,
    );
    if (!mounted || _video?.src != video.src || page != _pageUrl) return;
    if (saved != null &&
        saved.cues.isNotEmpty &&
        _session == null &&
        _fileCues == null) {
      _showFileCues(saved.cues, page, saved.language, imported: saved.imported);
      _canCarryOn = saved.canResume && video.playable;
    }
    if (saved != null && saved.imported) {
      toast(context, 'Dùng phụ đề đã nhập từ file');
      return;
    }
    if (!video.playable) {
      toast(context, 'Trang này giấu luồng video: hãy nhập phụ đề từ file (⋮)');
      return;
    }
    // An advert before the film is often what plays when CC is pressed.
    if (video.duration > 0 && video.duration < 90) {
      final go = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Có thể là quảng cáo'),
          content: Text(
            'Video đang chạy chỉ dài ${video.duration.round()} giây, nhiều '
            'khả năng là quảng cáo trước phim. Đợi phim chính chạy rồi bấm '
            'CC lại.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Vẫn làm'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Đợi phim'),
            ),
          ],
        ),
      );
      if (go != true || !mounted) return;
    }
    if (!await ensureModels(context)) return;
    var cookies = '';
    try {
      final list = await CookieManager.instance().getCookies(
        url: WebUri(video.src),
      );
      cookies = list.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {}
    if (!mounted || _session != null) return;
    if (_video?.src != video.src || _pageUrl != page) return;
    final alreadyRunning = ActiveWork.findVideo(id, page, video.duration);
    if (alreadyRunning != null) {
      _attachWork(alreadyRunning, video);
      return;
    }
    _send({'__vsub': 'clear'});
    _send(appSettings.subtitleOpts);
    final session = SubtitleSession(
      input: video.src,
      videoId: id,
      language: appSettings.language,
      headers: video.headers(cookies),
      saved: saved,
      mode: _mode,
    )..addListener(_onSession);
    session.duration = video.duration;
    if (saved != null) _sendAllCues(saved.cues);
    _saver = SessionSaver(
      session: session,
      page: page,
      source: video.src,
      videoId: id,
      title: title,
      duration: () => session.duration,
    );
    setState(() {
      _session = session;
      _sessionSrc = video.src;
      _otherVideo = false;
      // The session shows these lines (and more) from now on.
      _fileCues = null;
      _canCarryOn = false;
    });
    ActiveWork.begin(
      id,
      title.isEmpty ? (Uri.tryParse(page)?.host ?? page) : title,
      session,
      saver: _saver,
    );
    if (saved != null) {
      toast(context, 'Dùng lại ${saved.cues.length} dòng phụ đề đã lưu');
    }
    session.start(_video?.time ?? video.time);
  }

  /// CC with lines on the page: show or hide them; work goes on.
  void _toggleVisible() {
    setState(() => _hidden = !_hidden);
    if (_hidden) {
      _send({'__vsub': 'clear'});
    } else {
      _ackLogged = false;
      _sendAllCues(_session?.cues ?? _fileCues ?? const []);
    }
  }

  void _attachWork(ActiveWork work, WebVideo video) {
    if (!mounted) return;
    // Same film under a new signed address: keep the work, fetch through
    // the new link from now on (the old one may have expired).
    work.session.updateSource(video.src);
    if (_session != work.session) {
      _session?.removeListener(_onSession);
      setState(() {
        _session = work.session;
        _sessionSrc = video.src;
        _saver = work.saver;
        _fileCues = null;
        _canCarryOn = false;
        _hidden = false;
        _otherVideo = false;
      });
      work.session.addListener(_onSession);
    }
    _autoPage = _pageUrl;
    work.session.mode = _mode;
    work.session.foreground = widget.active;
    _sendAllCues(work.session.cues);
    _onSession();
  }

  /// Detach the view; the manager keeps its pipeline and autosave alive.
  void _detachSubtitles() {
    _session?.foreground = false;
    _session?.removeListener(_onSession);
    _session?.mode = SubtitleMode.whole;
    _saver?.save();
    _send({'__vsub': 'clear'});
    _session = null;
    _saver = null;
    _sessionSrc = '';
    _fileCues = null;
    _fileSource = '';
    _otherVideo = false;
    _canCarryOn = false;
    _sentCues.clear();
    _notifiedLanguage = '';
    widget.onWork();
  }

  Future<void> _chooseVideo() async {
    final candidates = _seen.values
        .map((e) => e.$1)
        .where((v) => !v.isAdvertisement)
        .toList();
    final choice = await showModalBottomSheet<WebVideo>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Chọn video để gắn phụ đề')),
            for (var i = 0; i < candidates.length; i++)
              ListTile(
                leading: Icon(
                  candidates[i].paused
                      ? Icons.pause_circle_outline
                      : Icons.play_circle_outline,
                ),
                title: Text(
                  'Video ${i + 1} · ${formatTime(candidates[i].duration)}',
                ),
                subtitle: Text(
                  candidates[i].src,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                selected: candidates[i].reportKey == _video?.reportKey,
                onTap: () => Navigator.pop(context, candidates[i]),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    _detachSubtitles();
    setState(() {
      _selectedVideoKey = choice.reportKey;
      _video = choice;
      _autoPage = '';
    });
    await _autoForPage(choice);
  }

  Future<void> _revise() async {
    final video = _video;
    final page = _pageUrl;
    if (video == null) return;
    final id = SubtitleStore.idForVideo(page, video.src);
    await showSubtitleRevision(
      context,
      videoId: id,
      language: _session?.language ?? _fileLanguage,
      currentCues: () => _video?.src == video.src && _pageUrl == page
          ? List.of(_session?.cues ?? _fileCues ?? [])
          : [],
      onApply: (next) async {
        if (!mounted || _video?.src != video.src || _pageUrl != page) {
          throw StateError('Bạn đã chuyển sang video khác');
        }
        if (_session case final SubtitleSession s) {
          s.applyCues(next);
          await ActiveWork.persist(id);
        } else {
          final saved = await SubtitleStore.loadVideo(
            page,
            video.src,
            duration: video.duration,
          );
          if (saved == null) throw StateError('Không còn phụ đề của video này');
          await SubtitleStore.save(saved.withCues(next));
          if (mounted && _video?.src == video.src && _pageUrl == page) {
            setState(() => _fileCues = next);
          }
        }
        if (mounted && _pageUrl == page && _video?.src == video.src) {
          _sendAllCues(next);
        }
      },
    );
  }

  Future<void> _changeLanguage() async {
    final video = _video;
    final page = _pageUrl;
    if (video == null) return;
    final language = await chooseVideoLanguage(
      context,
      _session?.language ?? _fileLanguage,
    );
    if (language == null ||
        !mounted ||
        _video?.src != video.src ||
        page != _pageUrl) {
      return;
    }
    if (_session case final SubtitleSession session) {
      await session.selectLanguage(language);
      await ActiveWork.persist(session.videoId);
    } else {
      final saved = await SubtitleStore.loadVideo(
        page,
        video.src,
        duration: video.duration,
      );
      if (saved != null) await SubtitleStore.save(saved.withLanguage(language));
      if (mounted && _video?.src == video.src && _pageUrl == page) {
        setState(() => _fileLanguage = language);
      }
    }
  }

  /// Stops making subtitles but keeps the lines made so far on screen;
  /// "Làm tiếp" carries on later.
  Future<void> _stopMaking() async {
    final session = _session;
    if (session == null) return;
    final cues = List.of(session.cues);
    final whole = coversWholeVideo(
      session.covered,
      session.duration,
      reachedEnd: session.reachedEnd,
    );
    final language = session.language;
    final (page, _) = await _pageInfo();
    if (!mounted || _session != session) return;
    AppLog.i('web', 'Dừng làm phụ đề (${cues.length} dòng)');
    await _stopSubtitles();
    _showFileCues(cues, page, language, imported: false);
    _canCarryOn = !whole && (_video?.playable ?? false);
  }

  void _onSession() {
    final session = _session;
    if (mounted && session?.stopped == true) {
      session!.removeListener(_onSession);
      setState(() {
        _fileCues = List.of(session.cues);
        _fileSource = session.input;
        _filePage = _pageUrl;
        _fileLanguage = session.language;
        _fileImported = false;
        _session = null;
        _saver = null;
        _canCarryOn = true;
      });
      return;
    }
    if (!mounted || session == null || _video?.src != session.input) return;
    if (!_hidden) {
      for (final cue in session.cues) {
        final key = (cue.start, cue.source);
        if (_sentCues[key] != (cue.end, cue.text)) {
          _send({'__vsub': 'cue', 'c': _cueData(cue)});
          _sentCues[key] = (cue.end, cue.text);
        }
      }
    }
    if (session.languageLocked && _notifiedLanguage != session.language) {
      _notifiedLanguage = session.language;
      toast(context, 'Đã nhận diện ${session.languageNotice}');
    }
    widget.onWork();
    if (mounted) setState(() {});
  }

  Future<void> _stopSubtitles() async {
    final stopping = ActiveWork.stop(_session);
    _hidden = false;
    _ackLogged = false;
    _canCarryOn = false;
    _session?.removeListener(_onSession);
    // Takes its copy of the lines before the session is disposed.
    _saver = null;
    _send({'__vsub': 'clear'});
    setState(() {
      _session = null;
      _sessionSrc = '';
      _otherVideo = false;
      _fileCues = null;
      _fileOffset = 0;
    });
    widget.onWork();
    await stopping;
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    _send({'__vsub': 'rate', 'v': speed});
  }

  Future<void> _openInPlayer() async {
    final video = _video;
    final originalPage = _pageUrl;
    if (video == null || !video.playable) return;
    var cookies = '';
    try {
      final list = await CookieManager.instance().getCookies(
        url: WebUri(video.src),
      );
      cookies = list.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {}
    final page = (await _web?.getUrl())?.toString() ?? video.page;
    final title = (await _web?.getTitle()) ?? '';
    if (!mounted || _pageUrl != originalPage || _video?.src != video.src) {
      return;
    }
    _send({'__vsub': 'pause'});
    // The player carries on making subtitles only if they were being made
    // here; it never starts on its own.
    final making = _session != null;
    _detachSubtitles();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: title.isEmpty ? 'Video từ web' : title,
          page: page,
          url: video.src,
          headers: video.headers(cookies),
          startAt: video.time,
          autoSubtitles: making,
        ),
      ),
    );
  }

  bool get _videoVisible =>
      _video != null &&
      DateTime.now().difference(_lastReport) < const Duration(seconds: 3);

  @override
  Widget build(BuildContext context) {
    // Turned sideways: the page gets the whole screen to show the film
    // big, with only a small subtitle control in the corner.
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    if (widget.active && landscape != _landscape) {
      _landscape = landscape;
      SystemChrome.setEnabledSystemUIMode(
        landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
      );
    }
    return SafeArea(
      bottom: false,
      top: !landscape,
      child: Column(
        children: [
          if (!landscape) _addressBar(),
          if (!landscape && _loading > 0 && _loading < 1)
            LinearProgressIndicator(value: _loading, minHeight: 2),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                _webView,
                // Subtitles being made for this page but not shown here
                // yet (video still loading, an advert first): say so.
                if (_session == null)
                  Positioned(top: 8, left: 8, right: 8, child: _pageWorkBar()),
                if (_videoVisible && !_panelHidden && !landscape)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: _videoPanel(),
                  ),
                if (_videoVisible && !_panelHidden && landscape)
                  Positioned(top: 8, right: 8, child: _compactPanel()),
                if (_videoVisible && _panelHidden)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: IconButton.filledTonal(
                      tooltip: 'Hiện thanh video',
                      icon: const Icon(Icons.video_settings),
                      onPressed: () => setState(() => _panelHidden = false),
                    ),
                  ),
                if (landscape)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: IconButton.filledTonal(
                      tooltip: 'Các tab đang mở',
                      icon: const Icon(Icons.tab),
                      onPressed: widget.onTabs,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Keep the platform view instance stable while tab labels and controls rebuild.
  late final Widget _webView = _buildWebView();

  Widget _buildWebView() => InAppWebView(
    // Google as the home page, so searching works at once.
    windowId: widget.tab.windowId,
    initialUrlRequest: widget.tab.windowId == null
        ? URLRequest(url: WebUri(widget.tab.initialUrl))
        : null,
    initialSettings: _settings,
    initialUserScripts: _scripts,
    // Without this the web view loads every pop-up over the
    // page being watched.
    onCreateWindow: (_, action) async {
      final target = action.request.url;
      if (!widget.active) return false;
      final page = await _web?.getUrl();
      if (!mounted || !widget.active) return false;
      if (appSettings.adBlock && shouldBlockPopup(target, page)) {
        _onBlocked('${target ?? ''}');
        return false;
      }
      return _openWindow(action.request, windowId: action.windowId);
    },
    onCloseWindow: (_) => widget.onClose(),
    onWebViewCreated: (c) {
      _web = c;
      c.addJavaScriptHandler(
        handlerName: 'vsub',
        callback: (args) => _onReport(args.isEmpty ? null : args.first),
      );
      c.addJavaScriptHandler(
        handlerName: 'vsubPopup',
        callback: (args) => _onBlocked(args.isEmpty ? '' : '${args.first}'),
      );
    },
    onLoadStart: (_, url) {
      // A new page: whatever video we knew about is gone.
      if (_session != null || _fileCues != null) {
        _detachSubtitles();
      }
      setState(() => _video = null);
      _onLoadStart('${url ?? ''}');
      widget.onPage(url: url?.toString(), title: '');
    },
    onLoadStop: (_, url) {
      if (_speed != 1) _send({'__vsub': 'rate', 'v': _speed});
      _onLoadStop('${url ?? ''}');
      _refreshHistory();
      if (!widget.active) _pauseBackground();
    },
    onTitleChanged: (_, title) => widget.onPage(title: title ?? ''),
    onReceivedError: (_, request, error) {
      if (request.isForMainFrame != true) return;
      final cancelled =
          error.type == WebResourceErrorType.CANCELLED ||
          error.description.contains('error -999') ||
          error.description.contains('code=102');
      if (cancelled) {
        AppLog.i(
          'web',
          'Yêu cầu trang bị hủy/chuyển hướng: ${AppLog.url('${request.url}')}',
        );
        return;
      }
      _slowLoad?.cancel();
      AppLog.e(
        'web',
        'Không tải được ${AppLog.url('${request.url}')}: '
            '${error.type} ${error.description}',
      );
      if (mounted && widget.active) {
        toast(
          context,
          'Không tải được trang: ${error.type}. Thử tải lại hoặc kiểm tra mạng.',
        );
      }
    },
    onReceivedHttpError: (_, request, response) {
      if (request.isForMainFrame != true) return;
      AppLog.e(
        'web',
        'Máy chủ trả lỗi ${response.statusCode} cho '
            '${AppLog.url('${request.url}')}',
      );
      if (mounted && widget.active) {
        toast(context, 'Trang web trả lỗi ${response.statusCode}');
      }
    },
    // iOS kills a page that uses too much memory and leaves it
    // blank; load it again.
    onWebContentProcessDidTerminate: (c) {
      AppLog.e('web', 'iOS đã tắt trang (thiếu bộ nhớ), tải lại');
      c.reload();
    },
    onProgressChanged: (_, p) => setState(() => _loading = p / 100),
    onUpdateVisitedHistory: (_, url, _) {
      if (url != null && url.toString() != 'about:blank') {
        _address.text = url.toString();
        _pageUrl = url.toString();
        _checkBookmark();
        widget.onPage(url: url.toString());
      }
      _refreshHistory();
    },
  );

  bool _landscape = false;

  Widget _pageWorkBar() {
    final work = ActiveWork.onPage(_pageUrl);
    if (work == null || work.hidden) return const SizedBox.shrink();
    final s = work.session;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => showSessionProgress(context, s, title: work.title),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 2, 12, 2),
          child: Row(
            children: [
              ActivityIcon(session: s, title: work.title),
              const SizedBox(width: 6),
              Expanded(
                child: ListenableBuilder(
                  listenable: s,
                  builder: (context, _) => Text(
                    'Đang làm phụ đề · ${s.stage}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The CC control alone, for watching sideways.
  Widget _compactPanel() {
    final session = _session;
    final active = session != null || _fileCues != null;
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(24),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: 'Ẩn thanh video',
              color: Colors.white,
              icon: const Icon(Icons.expand_less),
              onPressed: () => setState(() => _panelHidden = true),
            ),
            if (session != null)
              ActivityIcon(session: session, title: widget.tab.label),
            IconButton(
              tooltip: 'Lùi 10 giây',
              color: Colors.white,
              icon: const Icon(Icons.replay_10, size: 20),
              onPressed: () => _send({'__vsub': 'skip', 'by': -10}),
            ),
            IconButton(
              tooltip: 'Tới 10 giây',
              color: Colors.white,
              icon: const Icon(Icons.forward_10, size: 20),
              onPressed: () => _send({'__vsub': 'skip', 'by': 10}),
            ),
            if (active)
              IconButton(
                tooltip: 'Kiểu phụ đề',
                color: Colors.white,
                icon: const Icon(Icons.text_fields, size: 20),
                onPressed: () => showSubtitleStyle(context),
              ),
            IconButton(
              tooltip: 'Phụ đề',
              color: active && !_hidden ? Colors.lightBlueAccent : Colors.white,
              icon: Icon(
                active && !_hidden
                    ? Icons.closed_caption
                    : Icons.closed_caption_outlined,
              ),
              onPressed: active ? _toggleVisible : _startSubtitles,
            ),
          ],
        ),
      ),
    );
  }

  /// Opens what is on the clipboard. Shared text often wraps the link in
  /// other words ("Xem phim này https://…"), so the link is picked out.
  Future<void> _pasteAndGo() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (!mounted) return;
    if (text.isEmpty) {
      toast(context, 'Bộ nhớ tạm đang trống, hãy sao chép link trước');
      return;
    }
    final found = RegExp(r'https?://\S+').firstMatch(text)?.group(0);
    // A link at the end of a sentence carries its full stop or bracket.
    final link =
        found?.replaceFirst(RegExp(r'''[.,;:!?)\]'"]+$'''), '') ?? text;
    _address.text = link;
    _go(link);
  }

  /// Clears cache, cookies and site storage: the cure for pages stuck on
  /// a broken copy or an endless "checking your browser".
  Future<void> _clearWebData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá dữ liệu web?'),
        content: const Text(
          'Xoá bộ nhớ đệm (cache), cookie và dữ liệu các trang. Dùng khi '
          'trang bị lỗi hoặc cứ đòi kiểm tra trình duyệt mãi. Các trang đang '
          'đăng nhập sẽ phải đăng nhập lại.\n\n'
          'Phụ đề, thư viện video và chỗ xem dở không bị xoá.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final failed = <String>[];
    Future<void> step(String name, Future<void> Function() body) async {
      try {
        await body();
      } catch (e) {
        failed.add(name);
        AppLog.e('web', 'Xoá $name lỗi: $e');
      }
    }

    await step('cache', () => InAppWebViewController.clearAllCache());
    await step('cookie', () => CookieManager.instance().deleteAllCookies());
    await step(
      'dữ liệu trang',
      () => Platform.isIOS
          ? WebStorageManager.instance().removeDataModifiedSince(
              dataTypes: WebsiteDataType.ALL.toSet(),
              date: DateTime.fromMillisecondsSinceEpoch(0),
            )
          : WebStorageManager.instance().deleteAllData(),
    );
    AppLog.i('web', 'Đã xoá dữ liệu web');
    if (!mounted) return;
    toast(
      context,
      failed.isEmpty
          ? 'Đã xoá dữ liệu web'
          : 'Đã xoá, trừ: ${failed.join(', ')}',
    );
    await _web?.reload();
  }

  Widget _navigationButton({required bool forward}) {
    final enabled = forward ? _canForward : _canBack;
    return Tooltip(
      message: forward
          ? 'Đi tới (giữ để xem lịch sử)'
          : 'Quay lại (giữ để xem lịch sử)',
      triggerMode: TooltipTriggerMode.manual,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onLongPress: _showHistory,
        onTap: !enabled
            ? null
            : () {
                forward ? _web?.goForward() : _web?.goBack();
              },
        child: SizedBox(
          width: 40,
          height: 48,
          child: Icon(
            forward ? Icons.arrow_forward_ios : Icons.arrow_back_ios_new,
            size: 18,
            color: enabled ? null : Theme.of(context).disabledColor,
          ),
        ),
      ),
    );
  }

  Widget _addressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: [
          _navigationButton(forward: false),
          _navigationButton(forward: true),
          Expanded(
            child: TextField(
              controller: _address,
              focusNode: _addressFocus,
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.go,
              decoration: InputDecoration(
                hintText: 'Nhập địa chỉ web hoặc từ khoá',
                isDense: true,
                filled: true,
                contentPadding: const EdgeInsets.fromLTRB(14, 10, 0, 10),
                suffixIcon: ListenableBuilder(
                  listenable: _address,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_address.text.isNotEmpty)
                        IconButton(
                          tooltip: 'Xoá',
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.cancel, size: 18),
                          onPressed: () {
                            _address.clear();
                            _addressFocus.requestFocus();
                          },
                        ),
                      IconButton(
                        tooltip: 'Dán link và mở',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(Icons.content_paste_go, size: 20),
                        onPressed: _pasteAndGo,
                      ),
                    ],
                  ),
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(22),
                  borderSide: BorderSide.none,
                ),
              ),
              onSubmitted: _go,
            ),
          ),
          IconButton(
            tooltip: _bookmarked ? 'Bỏ lưu trang' : 'Lưu trang',
            visualDensity: VisualDensity.compact,
            icon: Icon(
              _bookmarked ? Icons.star : Icons.star_border,
              size: 22,
              color: _bookmarked ? Colors.amber : null,
            ),
            onPressed: _toggleBookmark,
          ),
          IconButton(
            tooltip: 'Các tab đang mở',
            visualDensity: VisualDensity.compact,
            icon: Container(
              width: 25,
              height: 25,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(
                  color: Theme.of(context).colorScheme.onSurface,
                  width: 1.5,
                ),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Text(
                '${widget.tabCount}',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            onPressed: widget.onTabs,
          ),
          PopupMenuButton<String>(
            tooltip: 'Thêm',
            icon: Icon(
              Icons.more_vert,
              size: 20,
              // A reminder when ad blocking is off.
              color: appSettings.adBlock ? null : Colors.orange,
            ),
            onSelected: (v) => switch (v) {
              'currentLinks' => appSettings.setBackgroundLinks(false),
              'backgroundLinks' => appSettings.setBackgroundLinks(true),
              'adblock' => _toggleAdBlock(),
              'home' => _go(kHomePage),
              'save' => _toggleBookmark(),
              'bookmarks' => _openBookmarks(),
              'clear' => _clearWebData(),
              'newtab' => widget.onNewTab(),
              'duplicate' => widget.onNewTab(url: _pageUrl),
              'history' => _showHistory(),
              'reload' => _web?.reload(),
              'panel' => setState(() => _panelHidden = !_panelHidden),
              _ => null,
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'newtab',
                child: ListTile(
                  leading: Icon(Icons.add),
                  title: Text('Tab mới'),
                ),
              ),
              const PopupMenuItem(
                value: 'duplicate',
                child: ListTile(
                  leading: Icon(Icons.open_in_new),
                  title: Text('Mở trang này trong tab mới'),
                ),
              ),
              const PopupMenuItem(
                value: 'history',
                child: ListTile(
                  leading: Icon(Icons.history),
                  title: Text('Lịch sử tab…'),
                ),
              ),
              const PopupMenuItem(
                value: 'reload',
                child: ListTile(
                  leading: Icon(Icons.refresh),
                  title: Text('Tải lại'),
                ),
              ),
              PopupMenuItem(
                value: 'panel',
                child: ListTile(
                  leading: Icon(
                    _panelHidden ? Icons.visibility : Icons.visibility_off,
                  ),
                  title: Text(
                    _panelHidden ? 'Hiện thanh video' : 'Ẩn thanh video',
                  ),
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'save',
                child: ListTile(
                  leading: Icon(
                    _bookmarked ? Icons.star : Icons.star_border,
                    color: _bookmarked ? Colors.amber : null,
                  ),
                  title: Text(
                    _bookmarked ? 'Bỏ lưu trang này' : 'Lưu trang này',
                  ),
                ),
              ),
              const PopupMenuItem(
                value: 'bookmarks',
                child: ListTile(
                  leading: Icon(Icons.bookmarks_outlined),
                  title: Text('Trang đã lưu…'),
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                enabled: false,
                child: Text('Liên kết mở cửa sổ mới'),
              ),
              CheckedPopupMenuItem(
                value: 'currentLinks',
                checked: !appSettings.backgroundLinks,
                child: const Text('Tab hiện tại'),
              ),
              CheckedPopupMenuItem(
                value: 'backgroundLinks',
                checked: appSettings.backgroundLinks,
                child: const Text('Tab mới (chạy nền)'),
              ),
              CheckedPopupMenuItem(
                value: 'adblock',
                checked: appSettings.adBlock,
                child: const Text('Chặn quảng cáo'),
              ),
              const PopupMenuItem(
                value: 'home',
                child: ListTile(
                  leading: Icon(Icons.home_outlined),
                  title: Text('Về trang Google'),
                ),
              ),
              const PopupMenuItem(
                value: 'clear',
                child: ListTile(
                  leading: Icon(Icons.cleaning_services_outlined),
                  title: Text('Xoá dữ liệu web'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// How much of the video has subtitles, and what the translator does.
  List<Widget> _progress(SubtitleSession session, WebVideo video) {
    final theme = Theme.of(context);
    final whole = coversWholeVideo(
      session.covered,
      video.duration,
      reachedEnd: session.reachedEnd,
    );
    final style = theme.textTheme.labelSmall;
    return [
      const SizedBox(height: 4),
      Text(
        '${subtitleProgressLabel(covered: session.covered, duration: video.duration, reachedEnd: whole)}'
        ' · ${session.cues.length} dòng',
        style: style?.copyWith(
          color: whole ? Colors.green : theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      if (video.duration > 0) ...[
        const SizedBox(height: 2),
        CoverageBar(
          covered: session.covered,
          duration: video.duration,
          position: video.time,
          done: whole,
          height: 5,
        ),
      ],
      Text(session.stage, style: style),
      Text(session.languageNotice, style: style),
    ];
  }

  Widget _videoPanel() {
    final video = _video!;
    final session = _session;
    final theme = Theme.of(context);
    final fileCues = _fileCues;
    final active = session != null || fileCues != null;
    String status;
    if (fileCues != null) {
      final offset = _fileOffset == 0
          ? ''
          : ' · lệch ${_fileOffset > 0 ? '+' : ''}'
                '${_fileOffset.toStringAsFixed(1)} giây';
      status = _fileImported
          ? 'Phụ đề từ file · '
                '${kSubtitleLanguages[_fileLanguage] ?? _fileLanguage}'
                ' · ${fileCues.length} dòng$offset'
          : 'Phụ đề đã làm trước · ${fileCues.length} dòng$offset';
    } else if (!video.playable) {
      status =
          'Trang này giấu luồng video nên không tự tạo được phụ đề. '
          'Nhập phụ đề từ file ở nút ⋮';
    } else if (session == null) {
      status = 'Đã thấy video · ${kLanguages[appSettings.language]} → Việt';
    } else if (_otherVideo) {
      status = 'Trang đang phát video khác (quảng cáo?), phụ đề tạm dừng';
    } else if (session.error != null || session.finished || session.paused) {
      status = session.status;
    } else {
      final lead = session.leadOver(video.time);
      status = lead < 2
          ? '${session.status} (đang đuổi theo video)'
          : 'Phụ đề sẵn trước ${lead.round()} giây';
    }
    // Compact buttons, so the row fits narrower iPhones too.
    return Theme(
      data: theme.copyWith(visualDensity: VisualDensity.compact),
      child: Material(
        color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (session != null) ...[
                    ActivityIcon(session: session, title: widget.tab.label),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          status,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall,
                        ),
                        if (session != null) ..._progress(session, video),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'Ẩn thanh video',
                    icon: const Icon(Icons.expand_more),
                    onPressed: () => setState(() => _panelHidden = true),
                  ),
                ],
              ),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  IconButton(
                    tooltip: 'Lùi 10 giây',
                    icon: const Icon(Icons.replay_10, size: 22),
                    onPressed: () => _send({'__vsub': 'skip', 'by': -10}),
                  ),
                  IconButton(
                    tooltip: 'Tới 10 giây',
                    icon: const Icon(Icons.forward_10, size: 22),
                    onPressed: () => _send({'__vsub': 'skip', 'by': 10}),
                  ),
                  PopupMenuButton<double>(
                    tooltip: 'Tốc độ',
                    initialValue: _speed,
                    onSelected: _setSpeed,
                    itemBuilder: (_) => [
                      for (final s in kSpeeds)
                        PopupMenuItem(value: s, child: Text(speedLabel(s))),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        speedLabel(_speed),
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: 'Thêm',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (v) => switch (v) {
                      'audio' => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => RetainedAudioScreen(
                            videoId: SubtitleStore.idForVideo(
                              _pageUrl,
                              video.src,
                            ),
                          ),
                        ),
                      ),
                      'language' => _changeLanguage(),
                      'revise' => _revise(),
                      'chooseVideo' => _chooseVideo(),
                      'import' => _importForPage(),
                      'library' => _useFromLibrary(),
                      'player' => _openInPlayer(),
                      'remove' => _stopSubtitles(),
                      'details' when session != null => showSessionDetails(
                        context,
                        session,
                      ),
                      'earlier' => _shiftFileCues(-0.5),
                      'whole' => appSettings.setSubWhole(true),
                      'follow' => appSettings.setSubWhole(false),
                      'later' => _shiftFileCues(0.5),
                      _ => null,
                    },
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'audio',
                        child: Text('Âm thanh lưu riêng…'),
                      ),
                      if (active)
                        const PopupMenuItem(
                          value: 'language',
                          child: Text('Ngôn ngữ của video…'),
                        ),
                      if (active)
                        const PopupMenuItem(
                          value: 'revise',
                          child: Text('Yêu cầu dịch lại…'),
                        ),
                      const PopupMenuItem(
                        value: 'chooseVideo',
                        child: Text('Chọn video để gắn phụ đề…'),
                      ),
                      const PopupMenuItem(
                        value: 'import',
                        child: Text('Nhập phụ đề từ file…'),
                      ),
                      const PopupMenuItem(
                        value: 'library',
                        child: Text('Dùng phụ đề từ kho…'),
                      ),
                      if (fileCues != null) ...[
                        const PopupMenuItem(
                          value: 'earlier',
                          child: Text('Phụ đề sớm hơn 0,5 giây'),
                        ),
                        const PopupMenuItem(
                          value: 'later',
                          child: Text('Phụ đề muộn hơn 0,5 giây'),
                        ),
                      ],
                      if (video.playable && fileCues == null) ...[
                        const PopupMenuDivider(),
                        CheckedPopupMenuItem(
                          value: 'whole',
                          checked: appSettings.subWhole,
                          child: const Text('Làm hết cả phim'),
                        ),
                        CheckedPopupMenuItem(
                          value: 'follow',
                          checked: !appSettings.subWhole,
                          child: const Text('Chỉ làm trước chỗ đang xem'),
                        ),
                      ],
                      if (session != null)
                        const PopupMenuItem(
                          value: 'details',
                          child: Text('Chi tiết phụ đề'),
                        ),
                      if (video.playable)
                        const PopupMenuItem(
                          value: 'player',
                          child: Text('Phát trong app (toàn màn hình)'),
                        ),
                      if (active)
                        const PopupMenuItem(
                          value: 'remove',
                          child: Text('Dừng dịch và bỏ phụ đề khỏi trang'),
                        ),
                    ],
                  ),
                  if (active)
                    IconButton(
                      tooltip: 'Kiểu phụ đề',
                      icon: const Icon(Icons.text_fields, size: 20),
                      onPressed: () => showSubtitleStyle(context),
                    ),
                  // Making subtitles: stop (keeping the lines) or carry on.
                  if (session != null)
                    IconButton(
                      tooltip: 'Dừng làm phụ đề (giữ các dòng đã có)',
                      icon: const Icon(Icons.pause_circle_outline, size: 24),
                      onPressed: _stopMaking,
                    )
                  else if (_canCarryOn && fileCues != null)
                    IconButton(
                      tooltip: 'Làm tiếp phần còn thiếu',
                      color: Colors.green,
                      icon: const Icon(Icons.play_circle, size: 26),
                      onPressed: _startSubtitles,
                    ),
                  IconButton.filledTonal(
                    tooltip: active
                        ? (_hidden ? 'Hiện phụ đề' : 'Ẩn phụ đề')
                        : 'Làm phụ đề',
                    isSelected: active && !_hidden,
                    icon: const Icon(Icons.closed_caption_outlined),
                    selectedIcon: const Icon(Icons.closed_caption),
                    onPressed: active ? _toggleVisible : _startSubtitles,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
