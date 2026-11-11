import 'package:flutter/material.dart';

import 'screens/browser_screen.dart';
import 'screens/library_screen.dart';
import 'screens/lock_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subtitle_library_screen.dart';
import 'services/app_settings.dart';
import 'services/subtitle_session.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const VideoSubApp());
}

class VideoSubApp extends StatefulWidget {
  const VideoSubApp({super.key});

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
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  /// Bumped on every visit so the subtitle list reloads.
  int _subsVisit = 0;

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
