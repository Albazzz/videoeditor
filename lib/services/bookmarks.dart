import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// A page the user saved to come back to.
class Bookmark {
  const Bookmark({
    required this.url,
    required this.title,
    required this.added,
    this.folder = '',
  });

  final String url;
  final String title;
  final DateTime added;
  final String folder;

  Bookmark copyWith({String? title, String? folder}) => Bookmark(
    url: url,
    title: title ?? this.title,
    folder: folder ?? this.folder,
    added: added,
  );

  bool matches(String query) {
    final haystack = '$title $url $folder'.toLowerCase();
    return query.toLowerCase().split(RegExp(r'\s+')).every(haystack.contains);
  }

  String get host => Uri.tryParse(url)?.host ?? url;

  Map<String, Object> toJson() => {
    'url': url,
    'folder': folder,
    'title': title,
    'added': added.millisecondsSinceEpoch,
  };

  static Bookmark? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    return Bookmark(
      url: j['url'] as String,
      folder: j['folder'] as String? ?? '',
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

  static Future<void>? _pending;

  // Two tabs can save or edit bookmarks before the first write completes.
  static Future<T> _change<T>(Future<T> Function(SharedPreferences) action) {
    Future<T> run() async => action(await SharedPreferences.getInstance());
    final previous = _pending;
    final work = previous == null ? run() : previous.then((_) => run());
    final finished = work.then<void>((_) {}, onError: (Object _) {});
    _pending = finished;
    return work.whenComplete(() {
      if (identical(_pending, finished)) _pending = null;
    });
  }

  static Future<List<String>> folders() async {
    final prefs = await SharedPreferences.getInstance();
    return (<String>{
      ...?prefs.getStringList('bookmarkFolders'),
      for (final b in await load())
        if (b.folder.isNotEmpty) b.folder,
    }).toList()..sort();
  }

  static Future<bool> createFolder(String name) => _change((prefs) async {
    final folder = name.trim();
    final names = await folders();
    if (folder.isEmpty || names.contains(folder)) return false;
    await prefs.setStringList('bookmarkFolders', [...names, folder]);
    return true;
  });

  static Future<bool> renameFolder(String from, String name) => _change(
    (prefs) => _changeFolder(prefs, from, name.trim(), delete: false),
  );
  static Future<bool> deleteFolder(String from) =>
      _change((prefs) => _changeFolder(prefs, from, '', delete: true));

  static Future<bool> _changeFolder(
    SharedPreferences prefs,
    String from,
    String to, {
    required bool delete,
  }) async {
    final names = await folders();
    if (!names.contains(from) ||
        (!delete && (to.isEmpty || names.contains(to)))) {
      return false;
    }
    await _write([
      for (final b in await load())
        b.folder == from ? b.copyWith(folder: to) : b,
    ]);
    names.remove(from);
    if (!delete) names.add(to);
    await prefs.setStringList('bookmarkFolders', names);
    if (prefs.getString('lastBookmarkFolder') == from) {
      await prefs.setString('lastBookmarkFolder', to);
    }
    return true;
  }

  static Future<Bookmark> add(String url, String title) =>
      _change((prefs) async {
        final all = await load();
        all.removeWhere((b) => key(b.url) == key(url));
        final last = prefs.getString('lastBookmarkFolder') ?? '';
        final bookmark = Bookmark(
          url: url,
          title: title,
          added: DateTime.now(),
          folder: (await folders()).contains(last) ? last : '',
        );
        await _write([bookmark, ...all]);
        return bookmark;
      });

  static Future<void> rename(String url, String title) =>
      update(url, title: title);
  static Future<void> move(String url, String folder) =>
      update(url, folder: folder);
  static Future<void> update(String url, {String? title, String? folder}) =>
      _change((prefs) async {
        final all = await load();
        final i = all.indexWhere((b) => key(b.url) == key(url));
        if (i < 0 ||
            (folder != null &&
                folder.isNotEmpty &&
                !(await folders()).contains(folder))) {
          return;
        }
        all[i] = all[i].copyWith(title: title?.trim(), folder: folder);
        await _write(all);
        if (folder != null) await prefs.setString('lastBookmarkFolder', folder);
      });

  static Future<void> remove(String url) => _change((prefs) async {
    final all = await load();
    all.removeWhere((b) => key(b.url) == key(url));
    await _write(all);
  });

  static Future<bool> contains(String url) async =>
      (await load()).any((b) => key(b.url) == key(url));
}
