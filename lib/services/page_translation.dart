import 'dart:io';

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
    retry: function () {
      failed = {};
      if (on) { scan(); pump(); }
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
      known = {}; failed = {};
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

/// Removes page translations persisted by earlier versions. New translations
/// live only in the open browser tab and are never written to disk.
class PageTranslations {
  static Directory? overrideDir;

  static String key(String page) =>
      Uri.tryParse(page)?.removeFragment().toString() ?? page.split('#').first;

  static Future<void> clearLegacy() async {
    final base = overrideDir ?? await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'page_tr'));
    if (await dir.exists()) await dir.delete(recursive: true);
  }
}

/// Answers translation requests using only this tab's in-memory cache.
class PageTranslator {
  PageTranslator({Translator Function()? engine})
    : _make = engine ?? (() => Translator.create(force: true, forPage: true));

  final Translator Function() _make;
  Translator? _engine;

  final _memo = <String, String>{};

  /// Lines being translated right now (for the bar on the page).
  final busy = ValueNotifier<int>(0);
  int translated = 0;
  String lastError = '';
  bool _disposed = false;
  int _generation = 0;

  Future<void> retry() async {
    if (_disposed) return;
    _generation++;
    final old = _engine;
    _engine = null;
    lastError = '';
    await old?.dispose();
  }

  Future<Map<String, String>> translate(
    List<String> texts, {
    required String page,
    String title = '',
    String htmlLang = '',
  }) async {
    if (_disposed) return {};
    final generation = _generation;
    final out = <String, String>{};
    final missing = <String>[];
    for (final t in texts) {
      final hit = _memo[t];
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
        if (_disposed || generation != _generation) return {};
        for (var i = 0; i < missing.length && i < got.length; i++) {
          final v = got[i]?.trim();
          if (v != null && v.isNotEmpty) out[missing[i]] = v;
        }
        lastError =
            got.length < missing.length ||
                got.any((v) => v == null || v.trim().isEmpty)
            ? 'Một số câu chưa dịch được'
            : '';
      } catch (e) {
        if (_disposed || generation != _generation) return {};
        lastError = '$e';
        AppLog.e('dịch trang', lastError);
      } finally {
        if (!_disposed) busy.value -= missing.length;
      }
    }
    if (_disposed) return {};
    if (_memo.length > 20000) _memo.clear();
    _memo.addAll(out);
    translated += out.length;
    return out;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _memo.clear();
    busy.dispose();
    await _engine?.dispose();
  }
}
