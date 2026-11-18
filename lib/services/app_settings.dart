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
  String language = 'auto';

  /// Show the original line above the Vietnamese one.
  bool showSource = false;

  /// Block adverts and pop-ups in the in-app browser.
  bool adBlock = true;
  bool backgroundLinks = false;
  bool parallelSubtitles = true;

  /// Translate recognised speech into Vietnamese. Off shows the
  /// original language.
  bool translate = true;

  /// 'device' (Google ML Kit, offline) or 'openrouter' (a language model,
  /// with the user's own key).
  String translateEngine = 'device';
  String openRouterModel = kDefaultOpenRouterModel;

  /// Kept in the Keychain, not with the other settings.
  String openRouterKey = '';

  String vercelModel = kVercel.defaultModel;
  String vercelKey = '';

  /// The AI service chosen for translation, or null for the phone's own.
  AiProvider? get aiProvider => aiProviderById(translateEngine);

  String keyFor(AiProvider p) => p == kVercel ? vercelKey : openRouterKey;
  String modelFor(AiProvider p) => p == kVercel ? vercelModel : openRouterModel;

  /// Translation goes to an AI service (one is chosen and has a key).
  bool get useCloud {
    final p = aiProvider;
    return p != null && keyFor(p).isNotEmpty;
  }

  static const _secure = FlutterSecureStorage();

  /// Make subtitles for the whole film, or only just ahead of the viewer.
  bool subWhole = true;

  /// Subtitle text size, 1 = normal.
  double subScale = 1;

  /// Gap between the subtitle and the bottom of the video, as a share of
  /// the video's height.
  double subLift = kDefaultSubLift;

  /// Opacity of the box behind subtitles; 0 draws an outline instead.
  double subBg = 0.72;

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    language = prefs.getString('language') ?? 'auto';
    showSource = prefs.getBool('showSource') ?? false;
    backgroundLinks = prefs.getBool('backgroundLinks') ?? false;
    parallelSubtitles = prefs.getBool('parallelSubtitles') ?? true;
    adBlock = prefs.getBool('adBlock') ?? true;
    translate = prefs.getBool('translate') ?? true;
    subScale = prefs.getDouble('subScale') ?? 1;
    subLift = prefs.getDouble('subLift') ?? kDefaultSubLift;
    subBg = prefs.getDouble('subBg') ?? 0.72;
    subWhole = prefs.getBool('subWhole') ?? true;
    translateEngine = prefs.getString('translateEngine') ?? 'device';
    openRouterModel =
        prefs.getString('openRouterModel') ?? kDefaultOpenRouterModel;
    vercelModel = prefs.getString('vercelModel') ?? kVercel.defaultModel;
    // The default became Mistral Small (Qwen on Alibaba's servers refuses
    // adult content). Move whoever was still on an old default, once.
    if (prefs.getBool('defaultModels2') != true) {
      if (openRouterModel == 'qwen/qwen3.7-flash') {
        openRouterModel = kDefaultOpenRouterModel;
        await prefs.setString('openRouterModel', openRouterModel);
      }
      if (vercelModel == 'mistral/mistral-nemo' ||
          vercelModel == 'alibaba/qwen3.7-flash') {
        vercelModel = kVercel.defaultModel;
        await prefs.setString('vercelModel', vercelModel);
      }
      await prefs.setBool('defaultModels2', true);
    }
    try {
      openRouterKey = await _secure.read(key: 'openrouter_key') ?? '';
      vercelKey = await _secure.read(key: 'vercel_key') ?? '';
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

  void setBackgroundLinks(bool value) {
    backgroundLinks = value;
    _prefs?.setBool('backgroundLinks', value);
    notifyListeners();
  }

  void setParallelSubtitles(bool value) {
    parallelSubtitles = value;
    _prefs?.setBool('parallelSubtitles', value);
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

  void setModel(AiProvider p, String value) {
    if (p == kVercel) {
      vercelModel = value;
      _prefs?.setString('vercelModel', value);
      notifyListeners();
    } else {
      setOpenRouterModel(value);
    }
  }

  Future<void> setKey(AiProvider p, String value) async {
    if (p != kVercel) return setOpenRouterKey(value);
    vercelKey = value.trim();
    try {
      if (vercelKey.isEmpty) {
        await _secure.delete(key: 'vercel_key');
      } else {
        await _secure.write(key: 'vercel_key', value: vercelKey);
      }
    } catch (_) {}
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

  void setSubWhole(bool value) {
    subWhole = value;
    _prefs?.setBool('subWhole', value);
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
