import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A page the user saved to come back to.
class Bookmark {
  const Bookmark({required this.url, required this.title, required this.added});

  final String url;
  final String title;
  final DateTime added;

  String get host => Uri.tryParse(url)?.host ?? url;

  Map<String, Object> toJson() => {
    'url': url,
    'title': title,
    'added': added.millisecondsSinceEpoch,
  };

  static Bookmark? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    return Bookmark(
      url: j['url'] as String,
      title: (j['title'] as String?) ?? '',
      added: DateTime.fromMillisecondsSinceEpoch((j['added'] as int?) ?? 0),
    );
  }
}

/// Saved pages, newest first, kept with the other settings.
class Bookmarks {
  static const _key = 'bookmarks';

  /// The same page with or without "#…" is one bookmark.
  static String key(String url) => url.split('#').first;

  static Future<List<Bookmark>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final list = jsonDecode(prefs.getString(_key) ?? '[]') as List;
      return [for (final j in list) ?Bookmark.fromJson(j)];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _write(List<Bookmark> all) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final b in all) b.toJson()]));
  }

  /// Adds [url] at the top (moving it there if it was saved before).
  static Future<void> add(String url, String title) async {
    final all = await load();
    all.removeWhere((b) => key(b.url) == key(url));
    all.insert(0, Bookmark(url: url, title: title, added: DateTime.now()));
    await _write(all);
  }

  static Future<void> remove(String url) async {
    final all = await load();
    all.removeWhere((b) => key(b.url) == key(url));
    await _write(all);
  }

  static Future<bool> contains(String url) async =>
      (await load()).any((b) => key(b.url) == key(url));
}
