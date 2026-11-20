import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_log.dart';
import 'openrouter_translator.dart';
import 'translator.dart';

/// Translates the text of a page in place, like a browser's translation.
///
/// Injected into the main frame on demand. Text near the screen goes
/// first (more as the page scrolls or grows); each distinct text is asked
/// for once. The originals are kept, so the page can switch back and forth.
/// The app answers through the 'vsubTr' handler with {original: Vietnamese}.
const String kTranslateScript = r'''
(function () {
  if (window.__vsubTr) return;
  var SKIP = /^(SCRIPT|STYLE|NOSCRIPT|TEXTAREA|INPUT|SELECT|OPTION|CODE|PRE|KBD|SAMP|SVG|MATH|IFRAME|CANVAS|VIDEO|AUDIO|TEMPLATE|HEAD|TITLE)$/;
  // Vietnamese letters: the text is already readable.
  var VI = /[ăâđêôơưạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]/i;
  // Some letter of a script worth translating.
  var LETTER = /[A-Za-zÀ-ɏͰ-ϿЀ-ӿ֐-ۿ฀-๿぀-ヿ㐀-鿿가-힯]/;
  var on = false, showing = true;
  var known = {}, asked = {}, failed = {};
  var waiting = [], mine = [];
  var originals = new WeakMap();
  var inflight = 0, scanTimer = null, pumpTimer = null, observer = null;

  function key(t) { return String(t).replace(/\s+/g, ' ').trim(); }
  function wanted(k) {
    return k.length >= 2 && k.length <= 3000 && LETTER.test(k) && !VI.test(k);
  }
  function skipped(el) {
    for (var n = el; n && n.nodeType === 1; n = n.parentElement) {
      if (SKIP.test(n.tagName) || n.isContentEditable) return true;
      if (n.getAttribute && n.getAttribute('translate') === 'no') return true;
      if (n.classList && n.classList.contains('notranslate')) return true;
    }
    return false;
  }
  function apply(node, k) {
    var v = known[k];
    if (!v) return false;
    if (!originals.has(node)) { originals.set(node, node.nodeValue); mine.push(node); }
    var raw = originals.get(node);
    var lead = raw.match(/^\s*/)[0], tail = raw.match(/\s*$/)[0];
    node.__vsubTr = lead + v + tail;
    if (showing && node.nodeValue !== node.__vsubTr) node.nodeValue = node.__vsubTr;
    return true;
  }
  function ours(n) {
    return n.__vsubTr !== undefined &&
      (n.nodeValue === n.__vsubTr || n.nodeValue === originals.get(n));
  }
  function scan() {
    scanTimer = null;
    if (!on || !document.body) return;
    var walker = document.createTreeWalker(document.body, 4, null);
    var n;
    while ((n = walker.nextNode())) {
      if (ours(n) || n.__vsubWait) continue;
      if (n.__vsubTr !== undefined) {
        // The page put new text in a node we had translated.
        originals.delete(n);
        n.__vsubTr = undefined;
      }
      var k = key(n.nodeValue || '');
      if (!wanted(k) || !n.parentElement || skipped(n.parentElement)) continue;
      if (!apply(n, k)) { n.__vsubWait = true; waiting.push(n); }
    }
    pump();
  }
  function soon() {
    if (on && !scanTimer) scanTimer = setTimeout(scan, 600);
  }
  function near(n) {
    var el = n.parentElement;
    if (!el || !el.getBoundingClientRect) return true;
    var r = el.getBoundingClientRect();
    if (!r.width && !r.height) return false;
    return r.bottom > -innerHeight && r.top < innerHeight * 3;
  }
  function pump() {
    pumpTimer = null;
    if (!on || inflight >= 2) return;
    var keep = [], i, n, k;
    // Settle what is already known first: no layout reads in between.
    for (i = 0; i < waiting.length; i++) {
      n = waiting[i];
      if (n.isConnected === false) { n.__vsubWait = false; continue; }
      k = key(n.nodeValue || '');
      if (known[k]) { apply(n, k); n.__vsubWait = false; continue; }
      keep.push(n);
    }
    waiting = keep;
    var batch = [], chars = 0, picked = {};
    for (i = 0; i < waiting.length && batch.length < 60; i++) {
      n = waiting[i];
      k = key(n.nodeValue || '');
      if (asked[k] || picked[k] || (failed[k] || 0) >= 2) continue;
      if (batch.length && chars + k.length > 2500) continue;
      if (!near(n)) continue;
      picked[k] = true;
      batch.push(k);
      chars += k.length;
    }
    if (!batch.length) return;
    for (i = 0; i < batch.length; i++) asked[batch[i]] = true;
    inflight++;
    var lang = '';
    try { lang = String(document.documentElement.lang || ''); } catch (e) {}
    var done = function (map) { got(map, batch); };
    try {
      window.flutter_inappwebview.callHandler('vsubTr', {
        texts: batch, lang: lang, page: location.href, title: document.title
      }).then(done, function () { done(null); });
    } catch (e) { done(null); }
  }
  function got(map, batch) {
    inflight--;
    for (var i = 0; i < batch.length; i++) {
      var k = batch[i];
      delete asked[k];
      if (map && typeof map[k] === 'string' && map[k]) known[k] = map[k];
      else failed[k] = (failed[k] || 0) + 1;
    }
    if (on) pump();
  }
  function later() {
    if (on && !pumpTimer) pumpTimer = setTimeout(pump, 300);
  }
  window.addEventListener('scroll', later, { passive: true });

  window.__vsubTr = {
    start: function (map) {
      for (var k in map || {}) known[k] = map[k];
      on = true;
      if (!showing) this.show(true);
      if (!observer && window.MutationObserver) {
        observer = new MutationObserver(function (records) {
          for (var i = 0; i < records.length; i++) {
            var t = records[i].target;
            if (records[i].type !== 'characterData' || !ours(t)) { soon(); return; }
          }
        });
      }
      if (observer && document.body) {
        observer.observe(document.body, { childList: true, subtree: true, characterData: true });
      }
      scan();
    },
    stop: function () {
      on = false;
      if (observer) observer.disconnect();
      for (var i = 0; i < mine.length; i++) {
        var n = mine[i];
        if (n.nodeValue === n.__vsubTr && originals.has(n)) n.nodeValue = originals.get(n);
        n.__vsubTr = undefined;
      }
      for (var j = 0; j < waiting.length; j++) waiting[j].__vsubWait = false;
      mine = []; waiting = []; originals = new WeakMap(); showing = true;
    },
    show: function (translated) {
      showing = !!translated;
      for (var i = 0; i < mine.length; i++) {
        var n = mine[i];
        var want = showing ? n.__vsubTr : originals.get(n);
        if (want !== undefined && n.nodeValue !== want) n.nodeValue = want;
      }
    },
    count: function () { return mine.length; }
  };
})();
''';

/// Language code from a page's `<html lang>` ("zh-CN" → "zh"), or 'auto'.
String pageLanguage(String htmlLang) {
  final code = htmlLang.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (code.length < 2 || code == 'vi') return 'auto';
  return code;
}

/// A guess at the language of [texts] from their letters, for the
/// on-device translator, which must be told.
String guessLanguage(Iterable<String> texts) {
  var kana = 0, han = 0, hangul = 0, cyrillic = 0, thai = 0, latin = 0;
  for (final t in texts) {
    for (final r in t.runes) {
      if (r >= 0x3040 && r <= 0x30FF) {
        kana++;
      } else if (r >= 0x3400 && r <= 0x9FFF) {
        han++;
      } else if (r >= 0xAC00 && r <= 0xD7AF) {
        hangul++;
      } else if (r >= 0x0400 && r <= 0x04FF) {
        cyrillic++;
      } else if (r >= 0x0E00 && r <= 0x0E7F) {
        thai++;
      } else if ((r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A)) {
        latin++;
      }
    }
  }
  if (kana > 0 && kana * 10 >= han) return 'ja';
  final top = [
    ('zh', han),
    ('ko', hangul),
    ('ru', cyrillic),
    ('th', thai),
    ('en', latin),
  ]..sort((a, b) => b.$2.compareTo(a.$2));
  return top.first.$2 == 0 ? 'en' : top.first.$1;
}

/// One page's translation as listed in the store.
class PageTranslationInfo {
  const PageTranslationInfo({
    required this.id,
    required this.page,
    required this.title,
    required this.count,
    required this.updated,
  });
  final String id, page, title;
  final int count;
  final DateTime updated;
}

/// Translations of pages, kept so a page opens translated again without
/// asking the AI twice (and so saved pages can show "Đã dịch trang").
class PageTranslations {
  static Directory? overrideDir;

  /// Bumped when a page's translation is written or deleted.
  static final changes = ValueNotifier<int>(0);

  static Future<Directory?> _dir() async {
    try {
      final base = overrideDir ?? await getApplicationSupportDirectory();
      return Directory(p.join(base.path, 'page_tr'))
        ..createSync(recursive: true);
    } catch (_) {
      return null;
    }
  }

  static String key(String page) =>
      Uri.tryParse(page)?.removeFragment().toString() ?? page.split('#').first;

  static String idFor(String page) =>
      sha1.convert(utf8.encode(key(page))).toString().substring(0, 24);

  static final _maps = <String, Map<String, String>>{};
  static final _titles = <String, String>{};
  static final _writes = <String, Timer>{};
  static Set<String>? _ids;

  /// The translation kept for [page] (original → Vietnamese), or empty.
  static Future<Map<String, String>> load(String page) async {
    final id = idFor(page);
    final cached = _maps[id];
    if (cached != null) return cached;
    final dir = await _dir();
    final file = dir == null ? null : File(p.join(dir.path, '$id.map.gz'));
    var map = <String, String>{};
    if (file != null && await file.exists()) {
      try {
        final data = jsonDecode(
          utf8.decode(gzip.decode(await file.readAsBytes())),
        );
        if (data is Map) map = data.map((k, v) => MapEntry('$k', '$v'));
      } catch (e) {
        AppLog.e('dịch trang', 'Không đọc được bản dịch đã lưu: $e');
      }
    }
    return _maps[id] = map;
  }

  /// Whether [page] has a kept translation.
  static Future<bool> has(String page) async =>
      (await ids()).contains(idFor(page));

  /// Ids of the pages with a kept translation.
  static Future<Set<String>> ids() async {
    final known = _ids;
    if (known != null) return known;
    final dir = await _dir();
    final out = <String>{};
    if (dir != null) {
      await for (final e in dir.list()) {
        final name = p.basename(e.path);
        if (name.endsWith('.json')) out.add(name.substring(0, name.length - 5));
      }
    }
    return _ids = out;
  }

  /// Adds new lines to [page]'s translation; written a moment later so a
  /// page translating piece by piece is not written for every piece.
  static Future<void> add(
    String page,
    String title,
    Map<String, String> more,
  ) async {
    if (more.isEmpty) return;
    final id = idFor(page);
    final map = await load(page);
    map.addAll(more);
    if (title.isNotEmpty) _titles[id] = title;
    _pages[id] = page;
    (await ids()).add(id);
    _writes[id]?.cancel();
    _writes[id] = Timer(const Duration(seconds: 2), () {
      _writes.remove(id);
      unawaited(_write(id, page, map));
    });
  }

  /// Writes pending translations now (tests, leaving a page).
  static Future<void> flush() async {
    final pending = Map.of(_writes);
    for (final t in pending.values) {
      t.cancel();
    }
    _writes.clear();
    for (final id in pending.keys) {
      final map = _maps[id];
      final page = _pages[id];
      if (map != null && page != null) await _write(id, page, map);
    }
  }

  static final _pages = <String, String>{};

  static Future<void> _write(
    String id,
    String page,
    Map<String, String> map,
  ) async {
    _pages[id] = page;
    final dir = await _dir();
    if (dir == null) return;
    try {
      final mapFile = File(p.join(dir.path, '$id.map.gz'));
      await mapFile.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(map))));
      await File(p.join(dir.path, '$id.json')).writeAsString(
        jsonEncode({
          'page': key(page),
          'title': _titles[id] ?? '',
          'count': map.length,
          'updated': DateTime.now().millisecondsSinceEpoch,
        }),
      );
      changes.value++;
    } catch (e) {
      AppLog.e('dịch trang', 'Chưa lưu được bản dịch trang: $e');
    }
  }

  /// Every translated page, newest first.
  static Future<List<PageTranslationInfo>> list() async {
    final dir = await _dir();
    if (dir == null) return const [];
    final out = <PageTranslationInfo>[];
    await for (final e in dir.list()) {
      final name = p.basename(e.path);
      if (e is! File || !name.endsWith('.json')) continue;
      try {
        final data = jsonDecode(await e.readAsString()) as Map;
        out.add(
          PageTranslationInfo(
            id: name.substring(0, name.length - 5),
            page: '${data['page'] ?? ''}',
            title: '${data['title'] ?? ''}',
            count: (data['count'] as num?)?.toInt() ?? 0,
            updated: DateTime.fromMillisecondsSinceEpoch(
              (data['updated'] as num?)?.toInt() ?? 0,
            ),
          ),
        );
      } catch (_) {}
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  /// Forgets [page]'s translation: it opens untranslated from now on.
  static Future<void> delete(String page) async {
    final id = idFor(page);
    _writes.remove(id)?.cancel();
    _maps.remove(id);
    _ids?.remove(id);
    final dir = await _dir();
    if (dir != null) {
      for (final name in ['$id.json', '$id.map.gz']) {
        final f = File(p.join(dir.path, name));
        if (await f.exists()) await f.delete();
      }
    }
    changes.value++;
  }

  @visibleForTesting
  static void resetCache() {
    for (final t in _writes.values) {
      t.cancel();
    }
    _writes.clear();
    _maps.clear();
    _titles.clear();
    _pages.clear();
    _ids = null;
  }
}

/// Answers a page's requests for translations: from memory, then the
/// page's kept translation, then the translator chosen in Settings.
class PageTranslator {
  PageTranslator({Translator Function()? engine})
    : _make = engine ?? (() => Translator.create(force: true, forPage: true));

  final Translator Function() _make;
  Translator? _engine;

  /// Shared by all tabs: menus and tags repeat across a site's pages.
  static final _memo = <String, String>{};

  /// Lines being translated right now (for the bar on the page).
  final busy = ValueNotifier<int>(0);
  int translated = 0;
  String lastError = '';

  Future<Map<String, String>> translate(
    List<String> texts, {
    required String page,
    String title = '',
    String htmlLang = '',
  }) async {
    final out = <String, String>{};
    final kept = await PageTranslations.load(page);
    final missing = <String>[];
    for (final t in texts) {
      final hit = _memo[t] ?? kept[t];
      if (hit != null) {
        out[t] = hit;
      } else {
        missing.add(t);
      }
    }
    if (missing.isNotEmpty) {
      busy.value += missing.length;
      try {
        final engine = _engine ??= _make();
        var lang = pageLanguage(htmlLang);
        if (lang == 'auto' && engine is! OpenRouterTranslator) {
          lang = guessLanguage(missing);
        }
        final got = await engine.translateBatch(missing, lang);
        for (var i = 0; i < missing.length && i < got.length; i++) {
          final v = got[i]?.trim();
          if (v != null && v.isNotEmpty) out[missing[i]] = v;
        }
        lastError = '';
      } catch (e) {
        lastError = '$e';
        AppLog.e('dịch trang', lastError);
      } finally {
        busy.value -= missing.length;
      }
    }
    if (_memo.length > 20000) _memo.clear();
    _memo.addAll(out);
    translated += out.length;
    await PageTranslations.add(page, title, out);
    return out;
  }

  Future<void> dispose() async {
    busy.dispose();
    await _engine?.dispose();
  }

  @visibleForTesting
  static void clearMemo() => _memo.clear();
}
