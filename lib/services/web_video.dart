import 'ad_block.dart';

/// What the page script reports about the video the user is watching.
class WebVideo {
  const WebVideo({
    required this.src,
    required this.time,
    required this.paused,
    required this.duration,
    required this.page,
    required this.userAgent,
    this.cueCount = 0,
    this.area = 0,
    this.muted = false,
    this.elementId = '',
  });

  /// Stream URL (mp4 / m3u8). Empty or `blob:` when the site hides it.
  final String src;
  final double time;
  final bool paused;
  final double duration;

  /// URL of the frame that holds the video (used as Referer).
  final String page;
  final String userAgent;

  /// Subtitle lines the frame currently holds. Fewer than the app has means
  /// the frame was reloaded and needs them again.
  final int cueCount;

  /// On-screen size in square pixels; adverts in hidden frames show 0.
  final int area;
  final bool muted;
  final String elementId;
  String get reportKey => elementId.isEmpty ? src : '$elementId|$src';

  /// How likely this is the film rather than an advert or a preview:
  /// big on screen, playing, with sound and longer than two minutes.
  double get score =>
      (area + 1) *
      (paused ? 1 : 3) *
      (duration >= 120 ? 5 : 1) *
      (muted ? 0.3 : 1);

  bool get playable => src.startsWith('http');

  bool get isAdvertisement {
    final uri = Uri.tryParse(src);
    final frame = Uri.tryParse(page);
    if (isAdHost(uri?.host ?? '') || isAdHost(frame?.host ?? '')) return true;
    final path = uri?.path.toLowerCase() ?? '';
    return (path.contains('/thumbs/') && path.contains('preview')) ||
        RegExp(r'/(?:images|static/media)/mobile-[^/]+\.mp4$').hasMatch(path);
  }

  /// The film among several videos reporting at once. [keep] (the one
  /// subtitles are being made for) stays chosen while it is on the page.
  static WebVideo? main(Iterable<WebVideo> videos, {String keep = ''}) {
    WebVideo? best;
    for (final v in videos) {
      if (v.isAdvertisement) continue;
      if (keep.isNotEmpty && (v.reportKey == keep || v.src == keep)) return v;
      if (best == null || v.score > best.score) best = v;
    }
    return best;
  }

  static WebVideo? fromMessage(Object? message) {
    if (message is! Map) return null;
    double num0(Object? v) => v is num && v.isFinite ? v.toDouble() : 0;
    return WebVideo(
      src: '${message['src'] ?? ''}',
      time: num0(message['t']),
      paused: message['paused'] == true,
      duration: num0(message['dur']),
      page: '${message['page'] ?? ''}',
      userAgent: '${message['ua'] ?? ''}',
      cueCount: num0(message['n']).toInt(),
      area: num0(message['area']).toInt(),
      muted: message['muted'] == true,
      elementId: '${message['element'] ?? ''}',
    );
  }

  /// Headers a server expects when the stream is fetched outside the page.
  Map<String, String> headers(String cookies) {
    // Frames written by script report "about:blank": no referer then.
    final origin = Uri.tryParse(page);
    final web =
        origin != null && origin.isScheme('http') ||
        origin != null && origin.isScheme('https');
    return {
      if (userAgent.isNotEmpty) 'User-Agent': userAgent,
      if (web) 'Referer': page,
      if (web) 'Origin': origin.origin,
      if (cookies.isNotEmpty) 'Cookie': cookies,
    };
  }
}

/// Injected into every frame. Finds the main <video>, reports its stream URL
/// and position four times a second, and accepts commands (speed, cues,
/// pause). Commands are relayed down into iframes because players often
/// live there.
///
/// Subtitles are drawn by the page itself, in a box laid over the video and
/// timed from the video's own clock, so they follow the player when the
/// page scrolls or resizes. A text track carries the same lines for the
/// system's full-screen player, where the page cannot draw.
const String kPageScript = r'''
(function () {
  if (window.__vsub) return;
  window.__vsub = true;
  var background = false;
  document.addEventListener('play', function (ev) {
    if (background && ev.target && ev.target.pause) ev.target.pause();
  }, true);

  // On pages that feed the player through a blob, remember the playlist.
  var playlist = '', playlists = [];
  var frameId = Date.now().toString(36) + Math.random().toString(36).slice(2);
  var nextElement = 0, cueElement = '', cueSource = '';
  function elementId(v) {
    if (!v.__vsubId) v.__vsubId = frameId + ':' + (++nextElement);
    return v.__vsubId;
  }
  function elementById(id) {
    var list = document.querySelectorAll('video');
    for (var i = 0; i < list.length; i++) if (elementId(list[i]) === id) return list[i];
    return null;
  }
  function note(u) {
    try {
      u = new URL(u, location.href).href;
      if (/\.m3u8(\?|#|$)/i.test(u) && playlists.indexOf(u) < 0) {
        playlists.push(u);
        playlist = playlists.length === 1 ? u : '';
      }
    } catch (e) {}
  }
  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (m, u) {
    note(u);
    return open.apply(this, arguments);
  };
  if (window.fetch) {
    var realFetch = window.fetch;
    window.fetch = function (r) {
      note(typeof r === 'string' ? r : r && r.url);
      return realFetch.apply(this, arguments);
    };
  }

  function pick() {
    var list = document.querySelectorAll('video'), best = null;
    for (var i = 0; i < list.length; i++) {
      var v = list[i];
      if (!best || (!v.paused && best.paused) ||
          (v.paused === best.paused && (v.duration || 0) > (best.duration || 0))) {
        best = v;
      }
    }
    return best;
  }

  // ---- subtitle lines, kept sorted by start time ----
  var cues = [], showSource = false;
  // Look chosen in the app: text size, height above the bottom of the
  // video (share of its height) and how dark the box behind is.
  var scale = 1, lift = 0.07, bg = 0.72;
  function sameStart(a, b) { return Math.abs(a - b) < 0.05; }
  function upsert(c) {
    for (var i = 0; i < cues.length; i++) {
      if (sameStart(cues[i].s, c.s)) { cues[i] = c; return; }
    }
    cues.push(c);
    cues.sort(function (a, b) { return a.s - b.s; });
  }
  function cueAt(t) {
    var lo = 0, hi = cues.length - 1, f = -1;
    while (lo <= hi) {
      var m = (lo + hi) >> 1;
      if (cues[m].s <= t) { f = m; lo = m + 1; } else { hi = m - 1; }
    }
    for (var i = f; i >= 0 && cues[i].s > t - 600; i--) {
      if (t < cues[i].e) return cues[i];
    }
    return null;
  }

  // ---- text track for the system full-screen player ----
  var track = null, trackVideo = null, fullscreen = false;
  function ensureTrack(v) {
    if (trackVideo !== v) {
      clearTrack();
      if (track) track.mode = 'disabled';
      trackVideo = v;
      track = v.addTextTrack('subtitles', 'Tiếng Việt', 'vi');
      var ownedTrack = track;
      fullscreen = !!v.webkitDisplayingFullscreen;
      track.mode = fullscreen ? 'showing' : 'hidden';
      v.addEventListener('webkitbeginfullscreen', function () {
        if (track !== ownedTrack || srcOf(v) !== cueSource) return;
        fullscreen = true;
        if (track) track.mode = 'showing';
      });
      v.addEventListener('webkitendfullscreen', function () {
        if (track !== ownedTrack) return;
        fullscreen = false;
        if (track) track.mode = 'hidden';
      });
      for (var i = 0; i < cues.length; i++) addTrackCue(cues[i]);
    }
    return track;
  }
  function addTrackCue(c) {
    if (!track) return;
    try {
      var list = track.cues;
      for (var i = list ? list.length - 1 : -1; i >= 0; i--) {
        if (sameStart(list[i].startTime, c.s)) track.removeCue(list[i]);
      }
      var Cue = window.VTTCue || window.TextTrackCue;
      track.addCue(new Cue(c.s, c.e, c.text));
    } catch (e) {}
  }
  function clearTrack() {
    if (!track) return;
    try {
      while (track.cues && track.cues.length) track.removeCue(track.cues[0]);
    } catch (e) {}
  }

  // ---- box drawn over the video ----
  var box = null, inner = null, main = null, orig = null, shown = '';
  function ensureBox() {
    if (box) return box;
    box = document.createElement('div');
    box.setAttribute('style',
      'position:fixed;left:0;bottom:0;display:none;pointer-events:none;' +
      'z-index:2147483647;text-align:center;box-sizing:border-box;' +
      'padding:0 4%;margin:0;transform:none;');
    inner = document.createElement('div');
    inner.setAttribute('style',
      'display:inline-block;max-width:100%;' +
      'color:#fff;border-radius:6px;padding:.18em .55em;line-height:1.3;' +
      'font-family:-apple-system,system-ui,sans-serif;font-weight:500;' +
      'white-space:pre-wrap;');
    style();
    orig = document.createElement('div');
    orig.setAttribute('style', 'font-size:.72em;opacity:.8;display:none;');
    main = document.createElement('div');
    inner.appendChild(orig);
    inner.appendChild(main);
    box.appendChild(inner);
    return box;
  }
  function style() {
    if (!inner) return;
    inner.style.background = 'rgba(0,0,0,' + bg + ')';
    // Without a box, an outline keeps the text readable on bright scenes.
    inner.style.textShadow = bg > 0.05 ? '0 1px 2px #000' :
        '-1px -1px 0 #000,1px -1px 0 #000,-1px 1px 0 #000,1px 1px 0 #000,0 0 4px #000';
  }
  function hide() { if (box) box.style.display = 'none'; }
  function draw() {
    if (!cues.length) return hide();
    var v = cueElement ? elementById(cueElement) : pick();
    if (v && cueSource && srcOf(v) !== cueSource) {
      clearTrack();
      return hide();
    }
    var c = v ? cueAt(v.currentTime || 0) : null;
    if (!v || !c || fullscreen) return hide();
    var r = v.getBoundingClientRect();
    if (r.width < 60 || r.height < 40 || r.bottom < 0 || r.top > innerHeight) {
      return hide();
    }
    var b = ensureBox();
    // Inside the page's own full-screen element, or it would be hidden.
    var host = document.fullscreenElement || document.webkitFullscreenElement ||
        document.body || document.documentElement;
    if (b.parentNode !== host) host.appendChild(b);
    var key = c.text + '\n' + (showSource ? c.src : '');
    if (key !== shown) {
      shown = key;
      main.textContent = c.text;
      var extra = showSource && c.src && c.src !== c.text ? c.src : '';
      orig.textContent = extra;
      orig.style.display = extra ? 'block' : 'none';
    }
    var bottom = innerHeight - Math.min(r.bottom, innerHeight) + r.height * lift;
    var size = Math.min(28, r.width * 0.042, r.height * 0.075) * scale;
    b.style.fontSize = Math.max(10, size) + 'px';
    b.style.left = r.left + 'px';
    b.style.width = r.width + 'px';
    b.style.bottom = Math.max(0, bottom) + 'px';
    b.style.display = 'block';
  }
  // Ten times a second is plenty for subtitles and spares busy pages the
  // layout work of every animation frame; without lines it barely runs.
  (function loop() {
    // The system's full screen only shows the text track. Follow it from
    // the video itself: the events are missed when the track is made
    // after the video went full screen.
    try {
      if (track && trackVideo) {
        var fs = !!trackVideo.webkitDisplayingFullscreen;
        if (fs !== fullscreen) {
          fullscreen = fs;
          track.mode = fs ? 'showing' : 'hidden';
        }
      }
    } catch (e) {}
    try { draw(); } catch (e) {}
    setTimeout(loop, cues.length ? 100 : 500);
  })();

  function toCue(a) { return { s: a[0], e: a[1], text: a[2], src: a[3] || '' }; }

  // The address the app knows this frame's video by.
  function srcOf(v) {
    var src = v.currentSrc || v.src || '';
    if (!src) {
      var s = v.querySelector('source');
      if (s) src = s.src;
    }
    if ((!src || /^blob:/.test(src)) && document.querySelectorAll('video').length === 1) src = playlist || src;
    return src;
  }

  function handle(d) {
    if (d.__vsub === 'background') {
      background = !!d.value;
      if (background) document.querySelectorAll('video,audio').forEach(function (m) { m.pause(); });
    }
    var v = d.element ? elementById(d.element) : pick();
    // Pages often hold adverts in other frames: commands are for the one
    // video the app chose ("target"), except clearing, which is for all.
    var mine = (!d.element || (v && elementId(v) === d.element)) &&
        (!d.target || (v && srcOf(v) === d.target));
    try {
      if (!mine && d.__vsub !== 'clear' && d.__vsub !== 'opts') {
        // not ours
      } else if (d.__vsub === 'rate') { if (v) v.playbackRate = d.v; }
      else if (d.__vsub === 'pause') { if (v) v.pause(); }
      else if (d.__vsub === 'seek') { if (v && isFinite(d.t)) v.currentTime = d.t; }
      else if (d.__vsub === 'skip') { if (v && isFinite(d.by)) v.currentTime = Math.max(0, (v.currentTime || 0) + d.by); }
      else if (d.__vsub === 'opts') {
        showSource = !!d.showSource;
        if (typeof d.scale === 'number') scale = d.scale;
        if (typeof d.lift === 'number') lift = d.lift;
        if (typeof d.bg === 'number') bg = d.bg;
        style();
        shown = '';
      }
      else if (d.__vsub === 'cue') {
        if (cueSource && (cueSource !== d.target || cueElement !== (d.element || ''))) {
          cues = []; clearTrack();
        }
        cueSource = d.target || ''; cueElement = d.element || '';
        var c = toCue(d.c);
        upsert(c);
        if (v) { ensureTrack(v); addTrackCue(c); }
      } else if (d.__vsub === 'cues') {
        cueSource = d.target || ''; cueElement = d.element || '';
        cues = (d.list || []).map(toCue);
        cues.sort(function (a, b) { return a.s - b.s; });
        clearTrack();
        if (v) {
          ensureTrack(v);
          for (var i = 0; i < cues.length; i++) addTrackCue(cues[i]);
        }
        shown = '';
      } else if (d.__vsub === 'clear') {
        cues = [];
        cueSource = ''; cueElement = '';
        clearTrack();
        shown = '';
        hide();
      }
    } catch (e) {}
    var frames = document.querySelectorAll('iframe');
    for (var j = 0; j < frames.length; j++) {
      try { frames[j].contentWindow.postMessage(d, '*'); } catch (e) {}
    }
  }
  window.__vsubSend = handle;

  // ---- long press: the app shows its own link menu (like Chrome) ----
  // The web view's own lookup misses links wrapped around a picture
  // inside other boxes (film thumbnails), so remember what was touched.
  var touched = null;
  document.addEventListener('touchstart', function (ev) {
    touched = ev.target;
  }, { capture: true, passive: true });
  window.__vsubPressed = function () {
    var a = null, img = null;
    for (var n = touched; n && n.nodeType === 1; n = n.parentElement) {
      if (!img && n.tagName === 'IMG') img = n;
      if (n.tagName === 'A' && n.href) { a = n; break; }
    }
    if (!img && a && a.querySelector) img = a.querySelector('img');
    var text = a ? (a.innerText || a.textContent || a.title || '') : '';
    return JSON.stringify({
      href: a ? String(a.href) : '',
      text: String(text).trim().slice(0, 200),
      img: img ? String(img.currentSrc || img.src || '') : ''
    });
  };
  window.addEventListener('message', function (ev) {
    if (ev.data && ev.data.__vsub) handle(ev.data);
  });

  // On iPhone a video without "playsinline" jumps to the system's full
  // screen when it starts, where the page cannot draw subtitles. Keep it in
  // the page; turning the phone gives the big picture instead.
  function inline() {
    var all = document.getElementsByTagName('video');
    for (var k = 0; k < all.length; k++) {
      if (!all[k].hasAttribute('playsinline')) {
        all[k].setAttribute('playsinline', '');
        all[k].setAttribute('webkit-playsinline', '');
        all[k].playsInline = true;
      }
    }
  }
  document.addEventListener('DOMContentLoaded', inline);

  setInterval(function () {
    inline();
    if (!window.flutter_inappwebview) return;
    var videos = document.querySelectorAll('video');
    for (var vi = 0; vi < videos.length; vi++) {
    var v = videos[vi];
    var src = srcOf(v);
    if (!src) continue;
    // How much of the video can be seen: a hidden or tiny frame (adverts)
    // shows little or nothing.
    var r = v.getBoundingClientRect();
    var w = Math.max(0, Math.min(r.right, innerWidth) - Math.max(r.left, 0));
    var h = Math.max(0, Math.min(r.bottom, innerHeight) - Math.max(r.top, 0));
    try {
      window.flutter_inappwebview.callHandler('vsub', {
        src: src,
        element: elementId(v),
        t: v.currentTime || 0,
        paused: v.paused,
        dur: isFinite(v.duration) ? v.duration : 0,
        page: location.href,
        ua: navigator.userAgent,
        n: (!cueSource || cueSource === src) && (!cueElement || cueElement === elementId(v)) ? cues.length : 0,
        area: Math.round(w * h),
        muted: !!v.muted
      });
    } catch (e) {}
    }
  }, 250);
})();
''';
