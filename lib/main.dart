import 'package:flutter/material.dart';

import 'screens/browser_screen.dart';
import 'screens/saved_pages_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subtitle_library_screen.dart';
import 'screens/log_screen.dart';
import 'services/active_work.dart';
import 'services/background_subtitles.dart';
import 'widgets/background_subtitles_bar.dart';
import 'services/app_log.dart';
import 'services/app_settings.dart';
import 'services/open_page.dart';
import 'services/page_translation.dart';
import 'services/crash_trail.dart';
import 'services/subtitle_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppLog.init();
  try {
    await PageTranslations.clearLegacy();
  } catch (e) {
    AppLog.e('dịch trang', 'Chưa dọn được bản dịch trang cũ: $e');
  }
  final crash = await CrashTrail.init();
  if (crash != null) {
    AppLog.e(
      'văng',
      'Lần trước app tắt giữa chừng khi đang: ${crash.steps.join(' / ')}',
    );
  }
  BackgroundSubtitles.instance.initialize(
    onCancel: () async {
      for (final work in List.of(ActiveWork.all.value)) {
        await ActiveWork.stop(work.session);
      }
    },
    onOpen: () => openSubtitleLibrary.value++,
  );
  runApp(VideoSubApp(crash: crash));
}

class VideoSubApp extends StatefulWidget {
  const VideoSubApp({super.key, this.crash});

  /// What the previous run was doing when it was killed, if anything.
  final CrashReport? crash;

  @override
  State<VideoSubApp> createState() => _VideoSubAppState();
}

class _VideoSubAppState extends State<VideoSubApp> with WidgetsBindingObserver {
  /// null while the keychain is being read.
  bool? _hasKey;
  bool _locked = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    appSettings.load();
    SubtitleSession.cleanLeftovers();
    keyStore.hasKey(KeySlot.app).then((v) => setState(() => _hasKey = v));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      BackgroundSubtitles.instance.refreshNative();
    }
    // Leaving the app locks it again.
    if (state == AppLifecycleState.paused && _hasKey == true && !_locked) {
      setState(() => _locked = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasKey = _hasKey;
    return MaterialApp(
      title: 'Video Sub',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF3D7DFF),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      // The lock sits above the navigator so open screens survive a re-lock.
      builder: (context, child) => Stack(
        children: [
          ?child,
          if (hasKey == null)
            const ColoredBox(
              color: Colors.black,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_locked)
            LockScreen(
              key: ValueKey(hasKey),
              setup: !hasKey,
              onUnlocked: () => setState(() {
                _hasKey = true;
                _locked = false;
              }),
            ),
        ],
      ),
      home: HomeScreen(crash: widget.crash),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.crash});

  final CrashReport? crash;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  /// A page asked for elsewhere opens in the browser tab.
  void _toBrowser() {
    if ((openPageRequest.value != null || openPagesRequest.value != null) &&
        mounted) {
      setState(() => _tab = 0);
    }
  }

  @override
  void dispose() {
    openPageRequest.removeListener(_toBrowser);
    openPagesRequest.removeListener(_toBrowser);
    openSubtitleLibrary.removeListener(_toSubtitles);
    super.dispose();
  }

  void _toSubtitles() {
    if (mounted) {
      setState(() {
        _subsVisit++;
        _tab = 2;
      });
    }
  }

  /// Bumped on every visit so the subtitle list reloads.
  int _subsVisit = 0;
  int _savedVisit = 0;

  @override
  void initState() {
    super.initState();
    openPageRequest.addListener(_toBrowser);
    openPagesRequest.addListener(_toBrowser);
    openSubtitleLibrary.addListener(_toSubtitles);
    if (openSubtitleLibrary.value > 0) _tab = 2;
    final crash = widget.crash;
    if (crash != null || AppLog.previousNativeCrash != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _showCrash(crash ?? const CrashReport([])),
      );
    }
  }

  Future<void> _showCrash(CrashReport crash) async {
    // Lists, oldest first, the steps that never finished.
    final steps = crash.steps.isEmpty
        ? '• (không rõ)'
        : crash.steps.map((s) => '• $s').join('\n');
    final hint = crash.inTranslator
        ? '\n\nCó vẻ do bộ dịch. Tắt dịch để xem phụ đề tiếng gốc '
              'trong lúc chờ sửa?'
        : '';
    final turnOff = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Lần trước app bị văng'),
        content: Text(
          'Lúc đó app đang:\n$steps\n\n'
          'Nếu là bạn tự tắt app thì bỏ qua. Nếu không, bấm "Xem nhật ký" '
          'rồi "Sao chép để gửi" và gửi cho người làm app.$hint',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Đóng'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, false);
              Navigator.push(
                this.context,
                MaterialPageRoute(builder: (_) => const LogScreen()),
              );
            },
            child: const Text('Xem nhật ký'),
          ),
          if (crash.inTranslator && appSettings.translate)
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Tắt dịch'),
            ),
        ],
      ),
    );
    if (turnOff == true) appSettings.setTranslate(false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          const BrowserScreen(),
          // Watching on the web works well now; saved pages are what is
          // reached for. The video library sits in Settings.
          SavedPagesScreen(visit: _savedVisit),
          SubtitleLibraryScreen(visit: _subsVisit),
          const SettingsScreen(),
        ],
      ),
      // Watching sideways in the browser: no tab bar over the film.
      bottomNavigationBar:
          _tab == 0 &&
              MediaQuery.orientationOf(context) == Orientation.landscape
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                BackgroundSubtitlesBar(onOpen: _toSubtitles),
                NavigationBar(
                  height: 60,
                  selectedIndex: _tab,
                  onDestinationSelected: (i) => setState(() {
                    if (i == 2 && _tab != 2) _subsVisit++;
                    if (i == 1 && _tab != 1) _savedVisit++;
                    _tab = i;
                  }),
                  destinations: [
                    NavigationDestination(
                      icon: Icon(Icons.public),
                      label: 'Xem web',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.bookmarks_outlined),
                      label: 'Trang lưu',
                    ),
                    NavigationDestination(
                      // How many films are having subtitles made right now.
                      icon: ValueListenableBuilder(
                        valueListenable: ActiveWork.all,
                        builder: (context, works, _) {
                          final n = works.where((w) => !w.hidden).length;
                          return Badge(
                            isLabelVisible: n > 0,
                            label: Text('$n'),
                            child: const Icon(Icons.subtitles_outlined),
                          );
                        },
                      ),
                      label: 'Phụ đề',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.settings_outlined),
                      label: 'Cài đặt',
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
