import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:video/services/hls_proxy.dart';

/// A 1x1 PNG, as image hosts require at the start of every upload.
final fakePng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0,
  0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
  0x60, 0x82,
]);

Uint8List tsPackets(int n) {
  final b = Uint8List(188 * n);
  for (var i = 0; i < n; i++) {
    b[i * 188] = 0x47;
  }
  return b;
}

void main() {
  test('playlists: pieces and nested playlists go through the relay', () {
    const media =
        '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n'
        '#EXTINF:4,\nobj/abc\n#EXTINF:4,\nhttps://img.example/x~tplv.image?sig=1\n';
    final out = rewritePlaylist(
      media,
      Uri.parse('https://cdn.example/hls/index.m3u8'),
      playlistUrl: (u) => 'P[$u]',
      segmentUrl: (u) => 'S[$u]',
    );
    expect(out, contains('S[https://cdn.example/hls/obj/abc]'));
    expect(out, contains('S[https://img.example/x~tplv.image?sig=1]'));
    expect(out, contains('URI="https://cdn.example/hls/key.bin"'));

    const master =
        '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI="a/index.m3u8"\n'
        '#EXT-X-STREAM-INF:BANDWIDTH=1\nv/index.m3u8\n';
    final m = rewritePlaylist(
      master,
      Uri.parse('https://cdn.example/master.m3u8'),
      playlistUrl: (u) => 'P[$u]',
      segmentUrl: (u) => 'S[$u]',
    );
    expect(m, contains('P[https://cdn.example/v/index.m3u8]'));
    expect(m, contains('URI="P[https://cdn.example/a/index.m3u8]"'));
  });

  test('a fake picture in front of a piece is cut off', () {
    final ts = tsPackets(4);
    expect(mediaStart(Uint8List.fromList([...fakePng, ...ts])), fakePng.length);
    expect(mediaStart(ts), 0);
    // Not a picture (encrypted, AAC…): passed on unchanged.
    expect(mediaStart(Uint8List.fromList([1, 2, 3, ...ts])), 0);
    final mp4 = Uint8List.fromList([0, 0, 0, 24, ...'styp'.codeUnits, 0, 0]);
    expect(
      mediaStart(Uint8List.fromList([...fakePng, ...mp4])),
      fakePng.length,
    );
  });

  final hasFfmpeg = () {
    try {
      return Process.runSync('ffmpeg', ['-version']).exitCode == 0;
    } catch (_) {
      return false;
    }
  }();

  test(
    'ffmpeg reads a stream of disguised pieces through the relay',
    () async {
      final dir = await Directory.systemTemp.createTemp('hls_relay');
      addTearDown(() => dir.delete(recursive: true));
      // A 12 s stream in 4 s pieces, each saved as a "picture".
      final made = await Process.run('ffmpeg', [
        '-nostdin',
        '-loglevel',
        'error',
        '-f',
        'lavfi',
        '-i',
        'sine=f=300:d=12',
        '-c:a',
        'aac',
        '-f',
        'hls',
        '-hls_time',
        '4',
        '-hls_segment_filename',
        p.join(dir.path, 'seg%d.ts'),
        p.join(dir.path, 'real.m3u8'),
      ]);
      expect(made.exitCode, 0, reason: '${made.stderr}');
      final lines = <String>[];
      for (final l in File(p.join(dir.path, 'real.m3u8')).readAsLinesSync()) {
        if (l.endsWith('.ts')) {
          final name = 'obj${l.replaceAll(RegExp(r'\D'), '')}';
          File(p.join(dir.path, name)).writeAsBytesSync([
            ...fakePng,
            ...File(p.join(dir.path, l)).readAsBytesSync(),
          ]);
          lines.add(name);
        } else {
          lines.add(l);
        }
      }
      File(p.join(dir.path, 'fake.m3u8')).writeAsStringSync(lines.join('\n'));

      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var sawReferer = false;
      origin.listen((req) async {
        sawReferer |= req.headers.value('referer') == 'https://film.example/';
        final f = File(p.join(dir.path, req.uri.pathSegments.last));
        if (f.existsSync()) {
          req.response.add(f.readAsBytesSync());
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });

      final relay = await HlsProxy.start({'Referer': 'https://film.example/'});
      addTearDown(relay.close);
      final out = p.join(dir.path, 'out.wav');
      final run = await Process.run('ffmpeg', [
        '-nostdin',
        '-y',
        '-loglevel',
        'error',
        '-allowed_segment_extensions',
        'ALL',
        '-extension_picky',
        '0',
        '-i',
        relay.urlFor('http://127.0.0.1:${origin.port}/fake.m3u8'),
        '-vn',
        '-ac',
        '1',
        '-ar',
        '16000',
        out,
      ]);
      expect(run.exitCode, 0, reason: '${run.stderr}');
      // 12 s of 16 kHz 16-bit mono is about 384 KB.
      expect(File(out).lengthSync(), greaterThan(300000));
      expect(relay.stripped, greaterThanOrEqualTo(3));
      expect(sawReferer, isTrue);
    },
    skip: hasFfmpeg ? false : 'needs ffmpeg on PATH',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
