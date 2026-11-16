import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/cue.dart';
import '../models/subtitle_file.dart';
import '../services/ad_block.dart';
import '../services/active_work.dart';
import '../services/app_log.dart';
import '../services/app_settings.dart';
import '../services/open_page.dart';
import '../services/subtitle_session.dart';
import '../services/keep_awake.dart';
import '../services/subtitle_store.dart';
import '../services/watch_position.dart';
import '../services/web_video.dart';
import '../widgets/activity_icon.dart';
import '../widgets/common.dart';
import '../widgets/subtitle_details.dart';
import '../widgets/subtitle_import.dart';
import '../widgets/subtitle_picker.dart';
import '../widgets/subtitle_style.dart';
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
  final _address = TextEditingController();
  final _addressFocus = FocusNode();
  InAppWebViewController? _web;
  double _loading = 0;

  WebVideo? _video;
  DateTime _lastReport = DateTime(0);
  SubtitleSession? _session;
  SessionSaver? _saver;
  String _sessionSrc = '';

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
  bool _autoBusy = false;
  DateTime _lastPositionSave = DateTime(0);

  /// Latest report of every video on the page (adverts included).
  final _seen = <String, (WebVideo, DateTime)>{};

  /// Videos already written to the log for this page.
  final _logged = <String>{};
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
    _seen.clear();
    _logged.clear();
    _loadStarted = DateTime.now();
    if (url.isNotEmpty && url != 'about:blank') _pageUrl = url;
    AppLog.i('web', 'Mở ${AppLog.url(url)}');
    _slowLoad?.cancel();
    _slowLoad = Timer(const Duration(seconds: 15), () {
      if (!mounted || _loading >= 1) return;
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

  /// Tells the user something was stopped and lets them open it anyway,
  /// because a real link to another site looks the same as an advert.
  void _onBlocked(String url) {
    if (!mounted) return;
    final now = DateTime.now();
    if (now.difference(_lastBlockNotice) < const Duration(seconds: 2)) return;
    _lastBlockNotice = now;
    final target = Uri.tryParse(url);
    final canOpen =
        target != null && target.hasScheme && !isAdHost(target.host);
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
                  onPressed: () =>
                      _web?.loadUrl(urlRequest: URLRequest(url: WebUri(url))),
                )
              : null,
        ),
      );
  }

  @override
  void initState() {
    super.initState();
    appSettings.addListener(_onSettings);
    openPageRequest.addListener(_openRequested);
  }

  void _openRequested() {
    final url = openPageRequest.value;
    if (url == null || url.isEmpty) return;
    AppLog.i('web', 'Mở lại trang từ kho phụ đề: ${AppLog.url(url)}');
    _address.text = url;
    _go(url);
  }

  SubtitleMode get _mode =>
      appSettings.subWhole ? SubtitleMode.whole : SubtitleMode.follow;

  /// Style changes show at once on the page.
  void _onSettings() {
    _session?.mode = _mode;
    if (_session != null || _fileCues != null) {
      _send(appSettings.subtitleOpts);
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    KeepAwake.set(false);
    appSettings.removeListener(_onSettings);
    openPageRequest.removeListener(_openRequested);
    _slowLoad?.cancel();
    _saver?.close();
    _session?.dispose();
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
        : {...message, 'target': target};
    _web?.evaluateJavascript(
      source: 'window.__vsubSend && window.__vsubSend(${jsonEncode(full)});',
    );
  }

  void _onReport(Object? message) {
    final report = WebVideo.fromMessage(message);
    if (report == null || !mounted) return;
    // Every frame with a video reports; adverts too. Keep the latest of
    // each and follow only the one that looks like the film.
    final now = DateTime.now();
    _seen[report.src] = (report, now);
    _seen.removeWhere(
      (_, e) => now.difference(e.$2) > const Duration(milliseconds: 2500),
    );
    final video = WebVideo.main(
      _seen.values.map((e) => e.$1),
      keep: _session != null ? _sessionSrc : '',
    );
    if (video == null || video.src != report.src) return;
    _lastReport = now;
    final changed = _video?.src != video.src;
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
      final other = video.src != _sessionSrc;
      if (other != _otherVideo) setState(() => _otherVideo = other);
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
    if (_autoPage != _pageUrl &&
        !_autoBusy &&
        video.duration >= WatchPosition.minDuration) {
      _autoForPage(video);
    }
    if (changed) setState(() {});
  }

  /// The film itself, not an advert, is playing on this page: bring
  /// back its subtitles and offer to carry on where the user stopped.
  Future<void> _autoForPage(WebVideo video) async {
    final page = _pageUrl;
    if (page.isEmpty) return;
    _autoBusy = true;
    try {
      final id = SubtitleStore.idFor(page);
      final saved = await SubtitleStore.load(id);
      final resume = await WatchPosition.load(id, duration: video.duration);
      if (!mounted || page != _pageUrl) return;
      _autoPage = page;
      if (resume != null && video.time < 10) _offerResume(resume);
      if (saved == null || saved.cues.isEmpty) return;
      if (_session != null || _fileCues != null) return;
      if (saved.imported) {
        AppLog.i('web', 'Tự hiện ${saved.cues.length} dòng đã nhập');
        _showFileCues(saved.cues, page, saved.language);
        toast(context, 'Đã bật phụ đề đã nhập cho phim này');
      } else if (saved.language == appSettings.language) {
        // Shown as they are; making more waits for the user ("Làm tiếp").
        if (!mounted) return;
        AppLog.i('web', 'Tự hiện ${saved.cues.length} dòng đã làm');
        _showFileCues(saved.cues, page, saved.language, imported: false);
        _canCarryOn = !saved.isWholeVideo && video.playable;
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
    final id = SubtitleStore.idFor(page);
    final choice = await pickSavedSubtitles(
      context,
      excludeId: id,
      pageTitle: title,
      duration: video?.duration ?? 0,
      canCarryOn: video?.playable == true,
    );
    if (choice == null || !mounted) return;
    final (src, use) = choice;
    if (_session != null || _fileCues != null) {
      // Let the current lines be written before the copy replaces them.
      final saver = _saver;
      _saver = null;
      final closing = saver?.close();
      _stopSubtitles();
      await closing;
    }
    await SubtitleStore.save(
      SavedSubs(
        id: id,
        title: title.isEmpty ? src.title : title,
        page: page,
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
    _autoPage = _pageUrl;
    if (!mounted) return;
    if (use == PickedUse.carryOn) {
      // The saved lines are reused only for the same spoken language.
      if (src.language != appSettings.language &&
          kLanguages.containsKey(src.language)) {
        appSettings.setLanguage(src.language);
      }
      await _startSubtitles();
    } else {
      _showFileCues(src.cues, page, src.language, imported: src.imported);
      _canCarryOn =
          !src.imported && !src.isWholeVideo && video?.playable == true;
      toast(
        context,
        'Đã dùng ${src.cues.length} dòng. Lệch giờ thì chỉnh ở ⋮ '
        '(sớm/muộn 0,5 giây)',
      );
    }
  }

  /// Reads a subtitle file for the page being watched.
  Future<void> _importForPage() async {
    final (page, title) = await _pageInfo();
    if (!mounted || page.isEmpty) return;
    final imported = await importSubtitleFile(context);
    if (imported == null || !mounted) return;
    await SubtitleStore.save(
      SavedSubs(
        id: SubtitleStore.idFor(page),
        title: title.isEmpty ? imported.fileName : title,
        page: page,
        language: imported.language,
        updated: DateTime.now(),
        cues: imported.cues,
        covered: const [],
        duration: _video?.duration ?? 0,
        complete: true,
        imported: true,
      ),
    );
    if (!mounted) return;
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
    final id = SubtitleStore.idFor(_filePage);
    final saved = await SubtitleStore.load(id);
    if (saved != null) await SubtitleStore.save(saved.withCues(shifted));
  }

  Future<void> _startSubtitles() async {
    final video = _video;
    AppLog.i('web', 'Bấm CC${video == null ? ' (chưa thấy video)' : ''}');
    if (video == null) return;
    final (page, title) = await _pageInfo();
    final saved = await SubtitleStore.load(SubtitleStore.idFor(page));
    if (!mounted) return;
    if (saved != null && saved.imported) {
      _showFileCues(saved.cues, page, saved.language);
      toast(context, 'Dùng phụ đề đã nhập từ file');
      return;
    }
    if (!video.playable) {
      toast(context, 'Trang này giấu luồng video: hãy nhập phụ đề từ file (⋮)');
      return;
    }
    if (!await ensureModels(context)) return;
    var cookies = '';
    try {
      final list = await CookieManager.instance().getCookies(
        url: WebUri(video.src),
      );
      cookies = list.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {}
    final reuse = saved != null && saved.language == appSettings.language;
    if (!mounted || _session != null) return;
    _send({'__vsub': 'clear'});
    _send(appSettings.subtitleOpts);
    void sendCue(Cue c) {
      if (!_hidden) _send({'__vsub': 'cue', 'c': _cueData(c)});
    }

    final session = SubtitleSession(
      input: video.src,
      language: appSettings.language,
      headers: video.headers(cookies),
      onCue: sendCue,
      initialCues: reuse ? saved.cues : const [],
      initialCovered: reuse ? saved.covered : const [],
      mode: _mode,
    )..addListener(_onSession);
    session.duration = video.duration;
    if (reuse) _sendAllCues(saved.cues);
    _saver = SessionSaver(
      session: session,
      page: page,
      title: title,
      duration: () => _video?.duration ?? 0,
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
      SubtitleStore.idFor(page),
      title.isEmpty ? (Uri.tryParse(page)?.host ?? page) : title,
      session,
    );
    if (reuse) {
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
    _stopSubtitles();
    _showFileCues(cues, page, language, imported: false);
    _canCarryOn = !whole && (_video?.playable ?? false);
  }

  void _onSession() {
    KeepAwake.update(_session);
    if (mounted) setState(() {});
  }

  void _stopSubtitles() {
    KeepAwake.set(false);
    _hidden = false;
    _ackLogged = false;
    ActiveWork.end(_session);
    _canCarryOn = false;
    _session?.removeListener(_onSession);
    // Takes its copy of the lines before the session is disposed.
    _saver?.close();
    _saver = null;
    _session?.dispose();
    _send({'__vsub': 'clear'});
    setState(() {
      _session = null;
      _sessionSrc = '';
      _otherVideo = false;
      _fileCues = null;
      _fileOffset = 0;
    });
  }

  void _setSpeed(double speed) {
    setState(() => _speed = speed);
    _send({'__vsub': 'rate', 'v': speed});
  }

  Future<void> _openInPlayer() async {
    final video = _video;
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
    if (!mounted) return;
    _send({'__vsub': 'pause'});
    _stopSubtitles();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: title.isEmpty ? 'Video từ web' : title,
          page: page,
          url: video.src,
          headers: video.headers(cookies),
          startAt: video.time,
          autoSubtitles: true,
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
    if (landscape != _landscape) {
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
              children: [
                InAppWebView(
                  // Google as the home page, so searching works at once.
                  initialUrlRequest: URLRequest(url: WebUri(kHomePage)),
                  initialSettings: _settings,
                  initialUserScripts: _scripts,
                  // Without this the web view loads every pop-up over the
                  // page being watched.
                  onCreateWindow: (_, action) async {
                    final target = action.request.url;
                    if (!appSettings.adBlock) return false;
                    final page = await _web?.getUrl();
                    if (!shouldBlockPopup(target, page)) return false;
                    _onBlocked('${target ?? ''}');
                    return true;
                  },
                  onWebViewCreated: (c) {
                    _web = c;
                    c.addJavaScriptHandler(
                      handlerName: 'vsub',
                      callback: (args) =>
                          _onReport(args.isEmpty ? null : args.first),
                    );
                    c.addJavaScriptHandler(
                      handlerName: 'vsubPopup',
                      callback: (args) =>
                          _onBlocked(args.isEmpty ? '' : '${args.first}'),
                    );
                  },
                  onLoadStart: (_, url) {
                    // A new page: whatever video we knew about is gone.
                    if (_session != null || _fileCues != null) {
                      _stopSubtitles();
                    }
                    setState(() => _video = null);
                    _onLoadStart('${url ?? ''}');
                  },
                  onLoadStop: (_, url) {
                    if (_speed != 1) _send({'__vsub': 'rate', 'v': _speed});
                    _onLoadStop('${url ?? ''}');
                  },
                  onReceivedError: (_, request, error) {
                    if (request.isForMainFrame != true) return;
                    AppLog.e(
                      'web',
                      'Không tải được ${AppLog.url('${request.url}')}: '
                          '${error.type} ${error.description}',
                    );
                  },
                  onReceivedHttpError: (_, request, response) {
                    if (request.isForMainFrame != true) return;
                    AppLog.e(
                      'web',
                      'Máy chủ trả lỗi ${response.statusCode} cho '
                          '${AppLog.url('${request.url}')}',
                    );
                  },
                  // iOS kills a page that uses too much memory and leaves it
                  // blank; load it again.
                  onWebContentProcessDidTerminate: (c) {
                    AppLog.e('web', 'iOS đã tắt trang (thiếu bộ nhớ), tải lại');
                    c.reload();
                  },
                  onProgressChanged: (_, p) =>
                      setState(() => _loading = p / 100),
                  onUpdateVisitedHistory: (_, url, _) {
                    if (url != null && url.toString() != 'about:blank') {
                      _address.text = url.toString();
                      _pageUrl = url.toString();
                    }
                  },
                ),
                if (_videoVisible && !landscape)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: _videoPanel(),
                  ),
                if (_videoVisible && landscape)
                  Positioned(top: 8, right: 8, child: _compactPanel()),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _landscape = false;

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
            if (session != null)
              ActivityIcon(
                session: session,
                title: ActiveWork.current.value?.title ?? '',
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

  Widget _addressBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back_ios_new, size: 18),
            onPressed: () => _web?.goBack(),
          ),
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
            tooltip: 'Tải lại',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => _web?.reload(),
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
              'adblock' => _toggleAdBlock(),
              'home' => _go(kHomePage),
              'clear' => _clearWebData(),
              _ => null,
            },
            itemBuilder: (_) => [
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
      if (session.translatorNote.isNotEmpty) ...[
        const SizedBox(height: 3),
        Text(session.translatorNote, style: style),
      ],
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
    return Material(
      color: theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            if (session != null) ...[
              ActivityIcon(
                session: session,
                title: ActiveWork.current.value?.title ?? '',
              ),
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
                    child: Text('Bỏ phụ đề khỏi trang'),
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
      ),
    );
  }
}
