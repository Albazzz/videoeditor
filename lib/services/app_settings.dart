import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'key_store.dart';
import 'openrouter_translator.dart';

export 'key_store.dart' show KeySlot;

const kLanguages = {
  'ja': 'Tiếng Nhật',
  'zh': 'Tiếng Trung',
  'yue': 'Tiếng Quảng Đông',
  'ko': 'Tiếng Hàn',
  'en': 'Tiếng Anh',
  'auto': 'Tự nhận diện',
};

const kDefaultSubLift = 0.07;

/// User preferences that are not secret.
class AppSettings extends ChangeNotifier {
  SharedPreferences? _prefs;

  /// Language spoken in the videos.
  String language = 'ja';

  /// Show the original line above the Vietnamese one.
  bool showSource = false;

  /// Block adverts and pop-ups in the in-app browser.
  bool adBlock = true;

  /// Translate recognised speech into Vietnamese. Off shows the
  /// original language.
  bool translate = true;

  /// 'device' (Google ML Kit, offline) or 'openrouter' (a language model,
  /// with the user's own key).
  String translateEngine = 'device';
  String openRouterModel = kDefaultOpenRouterModel;

  /// Kept in the Keychain, not with the other settings.
  String openRouterKey = '';

  bool get useOpenRouter =>
      translateEngine == 'openrouter' && openRouterKey.isNotEmpty;

  static const _secure = FlutterSecureStorage();

  /// Subtitle text size, 1 = normal.
  double subScale = 1;

  /// Gap between the subtitle and the bottom of the video, as a share of
  /// the video's height.
  double subLift = kDefaultSubLift;

  /// Opacity of the box behind subtitles; 0 draws an outline instead.
  double subBg = 0.72;

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    language = prefs.getString('language') ?? 'ja';
    showSource = prefs.getBool('showSource') ?? false;
    adBlock = prefs.getBool('adBlock') ?? true;
    translate = prefs.getBool('translate') ?? true;
    subScale = prefs.getDouble('subScale') ?? 1;
    subLift = prefs.getDouble('subLift') ?? kDefaultSubLift;
    subBg = prefs.getDouble('subBg') ?? 0.72;
    translateEngine = prefs.getString('translateEngine') ?? 'device';
    openRouterModel =
        prefs.getString('openRouterModel') ?? kDefaultOpenRouterModel;
    try {
      openRouterKey = await _secure.read(key: 'openrouter_key') ?? '';
    } catch (_) {}
    notifyListeners();
  }

  void setLanguage(String value) {
    language = value;
    _prefs?.setString('language', value);
    notifyListeners();
  }

  void setTranslate(bool value) {
    translate = value;
    _prefs?.setBool('translate', value);
    notifyListeners();
  }

  void setAdBlock(bool value) {
    adBlock = value;
    _prefs?.setBool('adBlock', value);
    notifyListeners();
  }

  void setTranslateEngine(String value) {
    translateEngine = value;
    _prefs?.setString('translateEngine', value);
    notifyListeners();
  }

  void setOpenRouterModel(String value) {
    openRouterModel = value;
    _prefs?.setString('openRouterModel', value);
    notifyListeners();
  }

  Future<void> setOpenRouterKey(String value) async {
    openRouterKey = value.trim();
    try {
      if (openRouterKey.isEmpty) {
        await _secure.delete(key: 'openrouter_key');
      } else {
        await _secure.write(key: 'openrouter_key', value: openRouterKey);
      }
    } catch (_) {}
    notifyListeners();
  }

  void setSubStyle({double? scale, double? lift, double? bg}) {
    if (scale != null) {
      subScale = scale;
      _prefs?.setDouble('subScale', scale);
    }
    if (lift != null) {
      subLift = lift;
      _prefs?.setDouble('subLift', lift);
    }
    if (bg != null) {
      subBg = bg;
      _prefs?.setDouble('subBg', bg);
    }
    notifyListeners();
  }

  /// What the page script needs to draw subtitles the user's way.
  Map<String, Object> get subtitleOpts => {
    '__vsub': 'opts',
    'showSource': showSource,
    'scale': subScale,
    'lift': subLift,
    'bg': subBg,
  };

  void setShowSource(bool value) {
    showSource = value;
    _prefs?.setBool('showSource', value);
    notifyListeners();
  }
}

final appSettings = AppSettings();
final keyStore = KeyStore();
