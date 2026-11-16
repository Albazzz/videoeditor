import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'app_log.dart';

/// A small relay on 127.0.0.1 that ffmpeg reads HLS through.
///
/// Film sites often host the pieces of a stream on image servers, so each
/// piece starts with a fake picture (PNG, JPEG, GIF) and has no video
/// extension. ffmpeg refuses those. The relay rewrites the playlist so
/// every piece is fetched through it, cuts the picture off the front, and
/// adds the page's headers (cookies, referer) to every request.
class HlsProxy {
  HlsProxy._(this._server, this._headers, this._client);

  final HttpServer _server;
  final Map<String, String> _headers;
  final http.Client _client;
  int stripped = 0;

  /// What went wrong last, for the details panel.
  String lastError = '';

  static Future<HlsProxy> start(Map<String, String> headers) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = HlsProxy._(server, headers, http.Client());
    server.listen(proxy._handle);
    return proxy;
  }

  /// The address ffmpeg should open instead of [playlist].
  String urlFor(String playlist) => _local('p', playlist);

  String _local(String kind, String target) =>
      'http://127.0.0.1:${_server.port}/$kind?u=${Uri.encodeQueryComponent(target)}';

  Future<void> _handle(HttpRequest req) async {
    final target = req.uri.queryParameters['u'];
    final kind = req.uri.path.replaceAll('/', '');
    try {
      if (target == null) throw const HttpException('no target');
      final res = await _client
          .get(Uri.parse(target), headers: _headers)
          .timeout(const Duration(seconds: 30));
      req.response.statusCode = res.statusCode;
      if (res.statusCode != 200) {
        lastError = 'máy chủ trả ${res.statusCode}';
        AppLog.e(
          'relay',
          'Máy chủ trả ${res.statusCode} cho ${AppLog.url(target)}',
        );
        await req.response.close();
        return;
      }
      if (kind == 'p') {
        req.response.headers.contentType = ContentType(
          'application',
          'vnd.apple.mpegurl',
        );
        req.response.write(
          rewritePlaylist(
            String.fromCharCodes(res.bodyBytes),
            Uri.parse(target),
            playlistUrl: (u) => _local('p', u),
            segmentUrl: (u) => _local('s', u),
          ),
        );
      } else {
        final body = res.bodyBytes;
        final start = mediaStart(body);
        if (start > 0) stripped++;
        req.response.add(start > 0 ? Uint8List.sublistView(body, start) : body);
      }
      await req.response.close();
    } catch (e) {
      lastError = '$e';
      AppLog.e('relay', 'Lỗi khi lấy ${AppLog.url(target ?? '')}: $e');
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> close() async {
    await _server.close(force: true);
    _client.close();
  }
}

/// Rewrites every address in an HLS playlist: nested playlists (in a
/// master playlist) through [playlistUrl], pieces through [segmentUrl].
/// Keys and init sections become absolute and are fetched directly.
String rewritePlaylist(
  String text,
  Uri base, {
  required String Function(String) playlistUrl,
  required String Function(String) segmentUrl,
}) {
  final master = text.contains('#EXT-X-STREAM-INF');
  final out = StringBuffer();
  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    if (line.isEmpty) {
      out.writeln();
    } else if (line.startsWith('#')) {
      // URI="…" inside tags (keys, audio renditions, init sections).
      out.writeln(
        line.replaceAllMapped(RegExp(r'URI="([^"]+)"'), (m) {
          final abs = base.resolve(m[1]!).toString();
          final isPlaylist =
              line.startsWith('#EXT-X-MEDIA') ||
              line.startsWith('#EXT-X-I-FRAME-STREAM-INF');
          return 'URI="${isPlaylist ? playlistUrl(abs) : abs}"';
        }),
      );
    } else {
      final abs = base.resolve(line).toString();
      out.writeln(master ? playlistUrl(abs) : segmentUrl(abs));
    }
  }
  return out.toString();
}

const _boxTypes = ['ftyp', 'styp', 'moof', 'sidx'];

bool _isBox(Uint8List b, int i) {
  for (final t in _boxTypes) {
    if (b[i] == t.codeUnitAt(0) &&
        b[i + 1] == t.codeUnitAt(1) &&
        b[i + 2] == t.codeUnitAt(2) &&
        b[i + 3] == t.codeUnitAt(3)) {
      return true;
    }
  }
  return false;
}

/// Where the real media starts in a downloaded piece: after a fake
/// picture put in front of an MPEG-TS or MP4 piece. 0 when nothing needs
/// cutting (or nothing is recognised: the piece is passed on unchanged).
int mediaStart(Uint8List b) {
  bool ts(int i) =>
      i + 376 < b.length &&
      b[i] == 0x47 &&
      b[i + 188] == 0x47 &&
      b[i + 376] == 0x47;
  if (b.isEmpty || ts(0)) return 0;
  // Only cut when the piece pretends to be a picture; anything else
  // (encrypted, AAC, fMP4) is left alone.
  final picture =
      (b.length > 8 &&
          b[0] == 0x89 &&
          b[1] == 0x50 &&
          b[2] == 0x4E &&
          b[3] == 0x47) ||
      (b.length > 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) ||
      (b.length > 6 &&
          b[0] == 0x47 &&
          b[1] == 0x49 &&
          b[2] == 0x46 &&
          b[3] == 0x38) ||
      (b.length > 2 && b[0] == 0x42 && b[1] == 0x4D);
  if (!picture) return 0;
  final limit = b.length < 65536 ? b.length : 65536;
  for (var i = 1; i < limit; i++) {
    if (b[i] == 0x47 && ts(i)) return i;
    // An MP4 box: 4-byte size, then a known type.
    if (i >= 4 && i + 4 <= b.length && _isBox(b, i)) return i - 4;
  }
  return 0;
}
