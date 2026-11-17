import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'app_log.dart';
import 'net.dart';

/// A small relay on 127.0.0.1 that ffmpeg reads HLS through.
///
/// Film sites often host the pieces of a stream on image servers, so each
/// piece starts with a fake picture (PNG, JPEG, GIF) and has no video
/// extension. ffmpeg refuses those. The relay rewrites the playlist so
/// every piece is fetched through it, cuts the picture off the front, and
/// adds the page's headers (cookies, referer) to every request.
class HlsProxy {
  HlsProxy._(this._server, this._headers);

  final HttpServer _server;
  final Map<String, String> _headers;
  int stripped = 0;
  bool _closed = false;

  /// What went wrong last, for the details panel.
  String lastError = '';

  static Future<HlsProxy> start(Map<String, String> headers) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final proxy = HlsProxy._(server, headers);
    server.listen(proxy._handle);
    return proxy;
  }

  /// The address ffmpeg should open instead of [playlist].
  String urlFor(String playlist) => _local('p', playlist);

  /// MP4 reads go through URLSession on iOS too. Fetch bounded ranges to
  /// avoid buffering an entire movie and preserve ffmpeg's seeking.
  String urlForFile(String video) => _local('f', video);

  String _local(String kind, String target) =>
      'http://127.0.0.1:${_server.port}/$kind?u=${Uri.encodeQueryComponent(target)}';

  Future<void> _handle(HttpRequest req) async {
    final target = req.uri.queryParameters['u'];
    final kind = req.uri.path.replaceAll('/', '');
    try {
      if (_closed) return;
      if (target == null) throw const HttpException('no target');
      if (kind == 'f') {
        await _file(req, Uri.parse(target));
        return;
      }
      // Fetched the way Safari fetches (see Net), so servers that turn
      // away other clients still answer.
      final (status, bytes) = await Net.get(Uri.parse(target), _headers);
      if (_closed) return;
      req.response.statusCode = status;
      if (status != 200) {
        lastError = 'máy chủ trả $status';
        AppLog.e('relay', 'Máy chủ trả $status cho ${AppLog.url(target)}');
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
            String.fromCharCodes(bytes),
            Uri.parse(target),
            playlistUrl: (u) => _local('p', u),
            segmentUrl: (u) => _local('s', u),
            resourceUrl: (u) => _local('r', u),
          ),
        );
      } else {
        final body = bytes;
        final start = kind == 'r' ? 0 : mediaStart(body);
        if (start > 0) stripped++;
        req.response.add(start > 0 ? Uint8List.sublistView(body, start) : body);
      }
      await req.response.close();
    } catch (e) {
      if (_closed) return;
      lastError = '$e';
      AppLog.e('relay', 'Lỗi khi lấy ${AppLog.url(target ?? '')}: $e');
      try {
        req.response.statusCode = 502;
        await req.response.close();
      } catch (_) {}
    }
  }

  Future<void> _file(HttpRequest req, Uri target) async {
    final requested = req.headers.value(HttpHeaders.rangeHeader);
    final range = requested == null
        ? null
        : RegExp(r'^bytes=(\d+)-(\d*)$').firstMatch(requested);
    if (requested != null && range == null) {
      req.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await req.response.close();
      return;
    }
    var offset = int.tryParse(range?[1] ?? '') ?? 0;
    final requestedEnd = int.tryParse(range?[2] ?? '');
    // Big enough that a film is not thousands of round trips.
    const block = 4 * 1024 * 1024;
    int? end;
    var first = true;
    while (!_closed) {
      var to = offset + block - 1;
      if (requestedEnd != null && to > requestedEnd) to = requestedEnd;
      if (end != null && to > end) to = end;
      final response = await Net.fetch(target, {
        ..._headers,
        'Range': 'bytes=$offset-$to',
      }, maxBytes: block);
      if (_closed) return;
      if (response.status != 200 && response.status != 206) {
        throw HttpException(
          'Máy chủ video trả ${response.status}',
          uri: target,
        );
      }
      final contentRange = RegExp(
        r'^bytes (\d+)-(\d+)/(\d+)$',
      ).firstMatch(response.headers['content-range'] ?? '');
      if (response.status == 206 &&
          (contentRange == null ||
              int.parse(contentRange[1]!) != offset ||
              int.parse(contentRange[2]!) > to ||
              int.parse(contentRange[2]!) - offset + 1 !=
                  response.bytes.length)) {
        throw const HttpException('Máy chủ trả sai khoảng dữ liệu video');
      }
      if (first) {
        first = false;
        req.response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
        req.response.headers.set(
          HttpHeaders.contentTypeHeader,
          response.headers['content-type'] ?? 'application/octet-stream',
        );
        if (contentRange != null) {
          final total = int.parse(contentRange[3]!);
          end = requestedEnd != null && requestedEnd < total
              ? requestedEnd
              : total - 1;
          req.response.statusCode = requested == null ? 200 : 206;
          req.response.contentLength = end - offset + 1;
          if (requested != null) {
            req.response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $offset-$end/$total',
            );
          }
        } else if (offset > 0) {
          throw const HttpException('Máy chủ không hỗ trợ tua video');
        } else {
          req.response.contentLength = response.bytes.length;
        }
      }
      req.response.add(response.bytes);
      await req.response.flush();
      offset += response.bytes.length;
      if (response.status == 200 ||
          response.bytes.isEmpty ||
          (end != null && offset > end)) {
        break;
      }
    }
    await req.response.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
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
  String Function(String)? resourceUrl,
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
          return 'URI="${isPlaylist ? playlistUrl(abs) : resourceUrl?.call(abs) ?? abs}"';
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
