import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'key_store.dart';

export 'key_store.dart' show KeySlot;

const kLanguages = {
  'ja': 'Tiếng Nhật',
  'zh': 'Tiếng Trung',
  'yue': 'Tiếng Quảng Đông',
  'ko': 'Tiếng Hàn',
  'en': 'Tiếng Anh',
  'auto': 'Tự nhận diện',
};

/// User preferences that are not secret.
class AppSettings extends ChangeNotifier {
  SharedPreferences? _prefs;

  /// Language spoken in the videos.
  String language = 'ja';

  /// Show the original line above the Vietnamese one.
  bool showSource = false;

  /// Block adverts and pop-ups in the in-app browser.
  bool adBlock = true;

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    language = prefs.getString('language') ?? 'ja';
    showSource = prefs.getBool('showSource') ?? false;
    adBlock = prefs.getBool('adBlock') ?? true;
    notifyListeners();
  }

  void setLanguage(String value) {
    language = value;
    _prefs?.setString('language', value);
    notifyListeners();
  }

  void setAdBlock(bool value) {
    adBlock = value;
    _prefs?.setBool('adBlock', value);
    notifyListeners();
  }

  void setShowSource(bool value) {
    showSource = value;
    _prefs?.setBool('showSource', value);
    notifyListeners();
  }
}

final appSettings = AppSettings();
final keyStore = KeyStore();
