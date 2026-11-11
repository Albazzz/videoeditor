/// What the page script reports about the video the user is watching.
class WebVideo {
  const WebVideo({
    required this.src,
    required this.time,
    required this.paused,
    required this.duration,
    required this.page,
    required this.userAgent,
  });

  /// Stream URL (mp4 / m3u8). Empty or `blob:` when the site hides it.
  final String src;
  final double time;
  final bool paused;
  final double duration;

  /// URL of the frame that holds the video (used as Referer).
  final String page;
  final String userAgent;

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
/// and position twice a second, and accepts commands (speed, cues, pause).
/// Commands are relayed down into iframes because players often live there.
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

  // Native fullscreen hides the app's overlay, so cues are also added to a
  // text track that the system player draws itself.
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
    }
    return track;
  }

  function handle(d) {
    var v = pick();
    try {
      if (v && d.__vsub === 'rate') v.playbackRate = d.v;
      else if (v && d.__vsub === 'pause') v.pause();
      else if (v && d.__vsub === 'cue') {
        var Cue = window.VTTCue || window.TextTrackCue;
        ensureTrack(v).addCue(new Cue(d.s, d.e, d.text));
      } else if (d.__vsub === 'clear' && track) {
        while (track.cues && track.cues.length) track.removeCue(track.cues[0]);
      }
    } catch (e) {}
    var frames = document.querySelectorAll('iframe');
    for (var i = 0; i < frames.length; i++) {
      try { frames[i].contentWindow.postMessage(d, '*'); } catch (e) {}
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
        ua: navigator.userAgent
      });
    } catch (e) {}
  }, 250);
})();
''';
