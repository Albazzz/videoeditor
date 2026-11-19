import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A page the user saved to come back to.
class Bookmark {
  const Bookmark({
    required this.url,
    required this.title,
    required this.added,
    this.folder = '',
    this.thumb = '',
  });

  final String url;
  final String title;
  final DateTime added;
  final String folder;

  /// File name of a small picture of the page (in [Bookmarks.thumbDir]),
  /// or empty.
  final String thumb;

  Bookmark copyWith({String? title, String? folder, String? thumb}) => Bookmark(
    url: url,
    title: title ?? this.title,
    folder: folder ?? this.folder,
    thumb: thumb ?? this.thumb,
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
    if (thumb.isNotEmpty) 'thumb': thumb,
  };

  static Bookmark? fromJson(Object? j) {
    if (j is! Map || j['url'] is! String) return null;
    return Bookmark(
      url: j['url'] as String,
      folder: j['folder'] as String? ?? '',
      title: (j['title'] as String?) ?? '',
      thumb: j['thumb'] as String? ?? '',
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

  /// The folder chosen last, offered first when saving the next page.
  static Future<String> lastFolder() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('lastBookmarkFolder') ?? '';
    return (await folders()).contains(last) ? last : '';
  }

  /// Saves [url] into [folder] (the user picks it; '' = top level).
  static Future<Bookmark> add(
    String url,
    String title, {
    String folder = '',
    String thumb = '',
  }) => _change((prefs) async {
    final all = await load();
    all.removeWhere((b) => key(b.url) == key(url));
    final known = folder.isEmpty || (await folders()).contains(folder);
    final bookmark = Bookmark(
      url: url,
      title: title.trim(),
      added: DateTime.now(),
      folder: known ? folder : '',
      thumb: thumb,
    );
    await _write([bookmark, ...all]);
    await prefs.setString('lastBookmarkFolder', bookmark.folder);
    return bookmark;
  });

  /// Where page pictures are kept. Null where there is no file system
  /// path (tests).
  static Future<Directory?> thumbDir() async {
    try {
      final base = await getApplicationSupportDirectory();
      return Directory(p.join(base.path, 'bookmark_thumbs'))
        ..createSync(recursive: true);
    } catch (_) {
      return null;
    }
  }

  /// The file name of [url]'s picture (one per page, also used by the
  /// subtitle store).
  static String thumbName(String url) =>
      '${sha1.convert(utf8.encode(key(url)))}.jpg';

  /// Stores a small picture of [url]'s page; returns its file name.
  static Future<String> saveThumb(String url, Uint8List jpeg) async {
    final dir = await thumbDir();
    if (dir == null || jpeg.isEmpty) return '';
    final name = thumbName(url);
    await File(p.join(dir.path, name)).writeAsBytes(jpeg, flush: true);
    return name;
  }

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
    final gone = all.where((b) => key(b.url) == key(url)).toList();
    all.removeWhere((b) => key(b.url) == key(url));
    await _write(all);
    for (final b in gone) {
      if (b.thumb.isEmpty) continue;
      final dir = await thumbDir();
      final file = dir == null ? null : File(p.join(dir.path, b.thumb));
      try {
        if (file != null && file.existsSync()) file.deleteSync();
      } catch (_) {}
    }
  });

  static Future<bool> contains(String url) async =>
      (await load()).any((b) => key(b.url) == key(url));
}
