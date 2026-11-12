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

  bool get playable => src.startsWith('http');

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
    );
  }

  /// Headers a server expects when the stream is fetched outside the page.
  Map<String, String> headers(String cookies) {
    final origin = Uri.tryParse(page);
    return {
      if (userAgent.isNotEmpty) 'User-Agent': userAgent,
      if (page.isNotEmpty) 'Referer': page,
      if (origin != null && origin.hasScheme) 'Origin': origin.origin,
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

  // On pages that feed the player through a blob, remember the playlist.
  var playlist = '';
  function note(u) {
    try {
      u = new URL(u, location.href).href;
      if (!playlist && /\.m3u8(\?|#|$)/i.test(u)) playlist = u;
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
    for (var i = f; i >= 0 && i >= f - 2; i--) {
      if (t < cues[i].e) return cues[i];
    }
    return null;
  }

  // ---- text track for the system full-screen player ----
  var track = null, trackVideo = null, fullscreen = false;
  function ensureTrack(v) {
    if (trackVideo !== v) {
      trackVideo = v;
      track = v.addTextTrack('subtitles', 'Tiếng Việt', 'vi');
      track.mode = fullscreen ? 'showing' : 'hidden';
      v.addEventListener('webkitbeginfullscreen', function () {
        fullscreen = true;
        if (track) track.mode = 'showing';
      });
      v.addEventListener('webkitendfullscreen', function () {
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
  var box = null, main = null, orig = null, shown = '';
  function ensureBox() {
    if (box) return box;
    box = document.createElement('div');
    box.setAttribute('style',
      'position:fixed;left:0;bottom:0;display:none;pointer-events:none;' +
      'z-index:2147483647;text-align:center;box-sizing:border-box;' +
      'padding:0 4%;margin:0;transform:none;');
    var inner = document.createElement('div');
    inner.setAttribute('style',
      'display:inline-block;max-width:100%;background:rgba(0,0,0,.72);' +
      'color:#fff;border-radius:6px;padding:.18em .55em;line-height:1.3;' +
      'font-family:-apple-system,system-ui,sans-serif;font-weight:500;' +
      'text-shadow:0 1px 2px #000;white-space:pre-wrap;');
    orig = document.createElement('div');
    orig.setAttribute('style', 'font-size:.72em;opacity:.8;display:none;');
    main = document.createElement('div');
    inner.appendChild(orig);
    inner.appendChild(main);
    box.appendChild(inner);
    return box;
  }
  function hide() { if (box) box.style.display = 'none'; }
  function draw() {
    requestAnimationFrame(draw);
    if (!cues.length) return hide();
    var v = pick();
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
    var bottom = innerHeight - Math.min(r.bottom, innerHeight) + r.height * 0.07;
    var size = Math.min(28, r.width * 0.042, r.height * 0.075);
    b.style.fontSize = Math.max(12, size) + 'px';
    b.style.left = r.left + 'px';
    b.style.width = r.width + 'px';
    b.style.bottom = Math.max(0, bottom) + 'px';
    b.style.display = 'block';
  }
  requestAnimationFrame(draw);

  function toCue(a) { return { s: a[0], e: a[1], text: a[2], src: a[3] || '' }; }

  function handle(d) {
    var v = pick();
    try {
      if (d.__vsub === 'rate') { if (v) v.playbackRate = d.v; }
      else if (d.__vsub === 'pause') { if (v) v.pause(); }
      else if (d.__vsub === 'opts') { showSource = !!d.showSource; shown = ''; }
      else if (d.__vsub === 'cue') {
        var c = toCue(d.c);
        upsert(c);
        if (v) { ensureTrack(v); addTrackCue(c); }
      } else if (d.__vsub === 'cues') {
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
  window.addEventListener('message', function (ev) {
    if (ev.data && ev.data.__vsub) handle(ev.data);
  });

  setInterval(function () {
    var v = pick();
    if (!v || !window.flutter_inappwebview) return;
    var src = v.currentSrc || v.src || '';
    if (!src) {
      var s = v.querySelector('source');
      if (s) src = s.src;
    }
    if (!src || /^blob:/.test(src)) src = playlist || src;
    if (!src) return;
    try {
      window.flutter_inappwebview.callHandler('vsub', {
        src: src,
        t: v.currentTime || 0,
        paused: v.paused,
        dur: isFinite(v.duration) ? v.duration : 0,
        page: location.href,
        ua: navigator.userAgent,
        n: cues.length
      });
    } catch (e) {}
  }, 250);
})();
''';
