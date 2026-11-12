import 'package:flutter/material.dart';

import 'screens/browser_screen.dart';
import 'screens/library_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subtitle_library_screen.dart';
import 'services/app_settings.dart';
import 'services/crash_trail.dart';
import 'services/subtitle_session.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final crash = await CrashTrail.init();
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

  /// Bumped on every visit so the subtitle list reloads.
  int _subsVisit = 0;

  @override
  void initState() {
    super.initState();
    final crash = widget.crash;
    if (crash != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showCrash(crash));
    }
  }

  Future<void> _showCrash(CrashReport crash) async {
    // Lists, oldest first, the steps that never finished.
    final steps = crash.steps.map((s) => '• $s').join('\n');
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
          'Nếu là bạn tự tắt app thì bỏ qua. Nếu không, chụp màn hình '
          'này gửi người làm app.$hint',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Đóng'),
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
          const LibraryScreen(),
          SubtitleLibraryScreen(key: ValueKey(_subsVisit)),
          const SettingsScreen(),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        height: 60,
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() {
          if (i == 2 && _tab != 2) _subsVisit++;
          _tab = i;
        }),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.public), label: 'Xem web'),
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            label: 'Thư viện',
          ),
          NavigationDestination(
            icon: Icon(Icons.subtitles_outlined),
            label: 'Phụ đề',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            label: 'Cài đặt',
          ),
        ],
      ),
    );
  }
}
