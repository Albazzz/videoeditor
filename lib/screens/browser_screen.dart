import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../models/cue.dart';
import '../services/ad_block.dart';
import '../services/app_settings.dart';
import '../services/subtitle_session.dart';
import '../services/subtitle_store.dart';
import '../services/web_video.dart';
import '../widgets/common.dart';
import '../widgets/subtitle_details.dart';
import 'player_screen.dart';

/// A browser that adds live Vietnamese subtitles to whatever video the page
/// is playing.
class BrowserScreen extends StatefulWidget {
  const BrowserScreen({super.key});

  @override
  State<BrowserScreen> createState() => _BrowserScreenState();
}

class _BrowserScreenState extends State<BrowserScreen> {
  final _address = TextEditingController();
  InAppWebViewController? _web;
  double _loading = 0;
  bool _started = false;

  WebVideo? _video;
  DateTime _lastReport = DateTime(0);
  SubtitleSession? _session;
  SessionSaver? _saver;
  String _sessionSrc = '';

  /// The page is playing a different video (an advert, the next
  /// episode) from the one subtitles are being made for.
  bool _otherVideo = false;
  Cue? _cue;
  double _speed = 1;
  DateTime _lastBlockNotice = DateTime(0);

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
      await web.setSettings(
        settings: InAppWebViewSettings(
          contentBlockers: on ? adBlockRules() : [],
        ),
      );
      if (_started) await web.reload();
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
  void dispose() {
    _saver?.close();
    _session?.dispose();
    _address.dispose();
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
    setState(() => _started = true);
    _web?.loadUrl(urlRequest: URLRequest(url: WebUri(text)));
  }

  void _send(Map<String, Object?> message) {
    _web?.evaluateJavascript(
      source: 'window.__vsubSend && window.__vsubSend(${jsonEncode(message)});',
    );
  }

  void _onReport(Object? message) {
    final video = WebVideo.fromMessage(message);
    if (video == null || !mounted) return;
    _lastReport = DateTime.now();
    final changed = _video?.src != video.src;
    _video = video;
    final session = _session;
    if (session != null) {
      // Adverts often play in their own <video> first; keep the session
      // and simply wait until the main video is back.
      final other = video.src != _sessionSrc;
      if (other != _otherVideo) setState(() => _otherVideo = other);
      if (other) {
        if (_cue != null) setState(() => _cue = null);
      } else {
        session.updatePosition(video.time);
        final cue = session.at(video.time);
        if (!identical(cue, _cue)) setState(() => _cue = cue);
      }
    }
    if (changed) setState(() {});
  }

  Future<void> _startSubtitles() async {
    final video = _video;
    if (video == null || !video.playable) return;
    if (!await ensureModels(context)) return;
    var cookies = '';
    try {
      final list = await CookieManager.instance().getCookies(
        url: WebUri(video.src),
      );
      cookies = list.map((c) => '${c.name}=${c.value}').join('; ');
    } catch (_) {}
    final page = (await _web?.getUrl())?.toString() ?? video.page;
    final title = (await _web?.getTitle()) ?? '';
    final saved = await SubtitleStore.load(SubtitleStore.idFor(page));
    final reuse = saved != null && saved.language == appSettings.language;
    if (!mounted || _session != null) return;
    _send({'__vsub': 'clear'});
    void sendCue(Cue c) =>
        _send({'__vsub': 'cue', 's': c.start, 'e': c.end, 'text': c.text});
    final session = SubtitleSession(
      input: video.src,
      language: appSettings.language,
      headers: video.headers(cookies),
      onCue: sendCue,
      initialCues: reuse ? saved.cues : const [],
      initialCovered: reuse ? saved.covered : const [],
    )..addListener(_onSession);
    if (reuse) saved.cues.forEach(sendCue);
    _saver = SessionSaver(session: session, page: page, title: title);
    setState(() {
      _session = session;
      _sessionSrc = video.src;
      _otherVideo = false;
    });
    if (reuse) {
      toast(context, 'Dùng lại ${saved.cues.length} dòng phụ đề đã lưu');
    }
    session.start(_video?.time ?? video.time);
  }

  void _onSession() {
    if (mounted) setState(() {});
  }

  void _stopSubtitles() {
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
      _cue = null;
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
    final session = _session;
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          _addressBar(),
          if (_loading > 0 && _loading < 1)
            LinearProgressIndicator(value: _loading, minHeight: 2),
          Expanded(
            child: Stack(
              children: [
                InAppWebView(
                  initialSettings: InAppWebViewSettings(
                    allowsInlineMediaPlayback: true,
                    mediaPlaybackRequiresUserGesture: false,
                    allowsBackForwardNavigationGestures: true,
                    javaScriptCanOpenWindowsAutomatically: false,
                    supportMultipleWindows: true,
                    useShouldOverrideUrlLoading: true,
                    contentBlockers: appSettings.adBlock ? adBlockRules() : [],
                  ),
                  initialUserScripts: UnmodifiableListView(_userScripts()),
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
                  shouldOverrideUrlLoading: (_, action) async {
                    final target = action.request.url;
                    if (appSettings.adBlock &&
                        action.isForMainFrame &&
                        target != null &&
                        isAdHost(target.host)) {
                      _onBlocked('$target');
                      return NavigationActionPolicy.CANCEL;
                    }
                    return NavigationActionPolicy.ALLOW;
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
                  onLoadStart: (_, _) {
                    // A new page: whatever video we knew about is gone.
                    if (_session != null) _stopSubtitles();
                    setState(() => _video = null);
                  },
                  onProgressChanged: (_, p) =>
                      setState(() => _loading = p / 100),
                  onUpdateVisitedHistory: (_, url, _) {
                    if (url != null && url.toString() != 'about:blank') {
                      _address.text = url.toString();
                    }
                  },
                  onLoadStop: (_, _) {
                    if (_speed != 1) _send({'__vsub': 'rate', 'v': _speed});
                  },
                ),
                if (!_started) const _StartHint(),
                if (session != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 84,
                    child: Center(child: SubtitleText(cue: _cue)),
                  ),
                if (_videoVisible)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 8,
                    child: _videoPanel(),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
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
              keyboardType: TextInputType.url,
              autocorrect: false,
              textInputAction: TextInputAction.go,
              decoration: InputDecoration(
                hintText: 'Nhập địa chỉ web hoặc từ khoá',
                isDense: true,
                filled: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
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
            tooltip: 'Chặn quảng cáo',
            icon: Icon(
              appSettings.adBlock ? Icons.shield : Icons.shield_outlined,
              size: 20,
              color: appSettings.adBlock
                  ? Theme.of(context).colorScheme.primary
                  : null,
            ),
            onPressed: _toggleAdBlock,
          ),
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => _web?.reload(),
          ),
        ],
      ),
    );
  }

  Widget _videoPanel() {
    final video = _video!;
    final session = _session;
    final theme = Theme.of(context);
    String status;
    if (!video.playable) {
      status = 'Trang này giấu luồng video nên không tạo được phụ đề';
    } else if (session == null) {
      status = 'Đã thấy video · ${kLanguages[appSettings.language]} → Việt';
    } else if (_otherVideo) {
      status = 'Trang đang phát video khác (quảng cáo?), phụ đề tạm dừng';
    } else if (session.error != null || session.finished) {
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
            Expanded(
              child: Text(
                status,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
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
            if (session != null)
              IconButton(
                tooltip: 'Chi tiết phụ đề',
                icon: const Icon(Icons.info_outline, size: 20),
                onPressed: () => showSessionDetails(context, session),
              ),
            IconButton(
              tooltip: 'Phát trong app',
              icon: const Icon(Icons.open_in_full, size: 20),
              onPressed: video.playable ? _openInPlayer : null,
            ),
            IconButton.filledTonal(
              tooltip: 'Phụ đề',
              isSelected: session != null,
              icon: const Icon(Icons.closed_caption_outlined),
              selectedIcon: const Icon(Icons.closed_caption),
              onPressed: !video.playable
                  ? null
                  : session == null
                  ? _startSubtitles
                  : _stopSubtitles,
            ),
          ],
        ),
      ),
    );
  }
}

class _StartHint extends StatelessWidget {
  const _StartHint();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ColoredBox(
      color: theme.colorScheme.surface,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.closed_caption,
                size: 56,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'Xem phim trên web có phụ đề Việt',
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Mở trang phim ở ô địa chỉ phía trên, bấm phát video, '
                'rồi bấm nút CC ở thanh hiện ra phía dưới.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
