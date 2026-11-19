import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
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
  test('byte-range media and init sections keep offsets and status', () async {
    final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => origin.close(force: true));
    origin.listen((r) async {
      if (r.uri.path == '/list') {
        r.response.write(
          '#EXTM3U\n#EXT-X-MAP:URI="init",BYTERANGE="3@1"\n#EXT-X-BYTERANGE:3@1\nseg\n',
        );
      } else if (r.headers.value('range') == 'bytes=1-3') {
        r.response.statusCode = 206;
        r.response.headers.set('Content-Range', 'bytes 1-3/5');
        r.response.write('bcd');
      } else {
        r.response.write('abcde');
      }
      await r.response.close();
    });
    final relay = await HlsProxy.start({});
    addTearDown(relay.close);
    final list = await http.read(
      Uri.parse(relay.urlFor('http://127.0.0.1:${origin.port}/list')),
    );
    final urls = RegExp(
      r'http[^"\s]+',
    ).allMatches(list).map((m) => Uri.parse(m[0]!)).toList();
    expect(urls, hasLength(2));
    for (final u in urls) {
      final got = await http.get(u, headers: {'Range': 'bytes=1-3'});
      expect(got.statusCode, 206);
      expect(got.headers['content-range'], 'bytes 1-3/5');
      expect(got.body, 'bcd');
    }
  });
  test(
    'MP4 relay preserves seeks and headers across bounded range reads',
    () async {
      final data = Uint8List.fromList(
        List.generate(4 * 1024 * 1024 + 317, (i) => i % 251),
      );
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      var calls = 0;
      origin.listen((req) async {
        expect(req.headers.value('referer'), 'https://film.example/');
        expect(req.headers.value('cookie'), 'session=test');
        final range = RegExp(
          r'bytes=(\d+)-(\d+)',
        ).firstMatch(req.headers.value('range')!)!;
        final start = int.parse(range[1]!);
        final requestedEnd = int.parse(range[2]!);
        expect(requestedEnd - start + 1, lessThanOrEqualTo(4 * 1024 * 1024));
        final end = requestedEnd < data.length ? requestedEnd : data.length - 1;
        calls++;
        req.response.statusCode = 206;
        req.response.headers.set(
          'content-range',
          'bytes $start-$end/${data.length}',
        );
        req.response.contentLength = end - start + 1;
        req.response.add(data.sublist(start, end + 1));
        await req.response.close();
      });
      final relay = await HlsProxy.start({
        'Referer': 'https://film.example/',
        'Cookie': 'session=test',
      });
      addTearDown(relay.close);
      final url = Uri.parse(
        relay.urlForFile('http://127.0.0.1:${origin.port}/video.mp4'),
      );
      final all = await http.get(url, headers: {'Range': 'bytes=17-'});
      expect(all.statusCode, 206);
      expect(
        all.headers['content-range'],
        'bytes 17-${data.length - 1}/${data.length}',
      );
      expect(all.bodyBytes, data.sublist(17));
      expect(calls, 2);
      final seek = await http.get(url, headers: {'Range': 'bytes=200-219'});
      expect(seek.statusCode, 206);
      expect(seek.bodyBytes, data.sublist(200, 220));
      expect(relay.lastError, isEmpty);
    },
  );

  test('keys and init sections can use the relay with page headers', () {
    final out = rewritePlaylist(
      '#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI="key.bin"\n#EXT-X-MAP:URI="init.mp4"\n',
      Uri.parse('https://cdn.example/master.m3u8'),
      playlistUrl: (u) => 'P[$u]',
      segmentUrl: (u) => 'S[$u]',
      resourceUrl: (u) => 'R[$u]',
    );
    expect(out, contains('URI="R[https://cdn.example/key.bin]"'));
    expect(out, contains('URI="R[https://cdn.example/init.mp4]"'));
  });
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

  test(
    'a slow piece asked for twice is fetched once, and the next one ahead',
    () async {
      final origin = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => origin.close(force: true));
      final fetched = <String>[];
      origin.listen((r) async {
        final name = r.uri.pathSegments.last;
        if (name == 'list') {
          r.response.write('#EXTM3U\n#EXTINF:4,\na.img\n#EXTINF:4,\nb.img\n');
        } else {
          fetched.add(name);
          await Future<void>.delayed(const Duration(milliseconds: 300));
          r.response.add([1, 2, 3]);
        }
        await r.response.close();
      });
      final relay = await HlsProxy.start({});
      addTearDown(relay.close);
      final list = await http.read(
        Uri.parse(relay.urlFor('http://127.0.0.1:${origin.port}/list')),
      );
      final urls = RegExp(
        r'^http\S+',
        multiLine: true,
      ).allMatches(list).map((m) => Uri.parse(m[0]!)).toList();
      // ffmpeg gave up on the first try and asks again meanwhile.
      final both = await Future.wait([http.get(urls[0]), http.get(urls[0])]);
      expect(both.map((r) => r.bodyBytes), everyElement([1, 2, 3]));
      final next = await http.get(urls[1]);
      expect(next.bodyBytes, [1, 2, 3]);
      expect(fetched, ['a.img', 'b.img']);
    },
  );

  test('the relay refuses addresses it did not sign (no open proxy)', () async {
    final relay = await HlsProxy.start({'Cookie': 'session=secret'});
    addTearDown(relay.close);
    final signed = Uri.parse(relay.urlFor('https://cdn.example/a.m3u8'));
    final port = signed.port;
    Future<int> status(String path) async {
      final c = HttpClient();
      try {
        final req = await c.getUrl(Uri.parse('http://127.0.0.1:$port$path'));
        return (await req.close()).statusCode;
      } finally {
        c.close(force: true);
      }
    }

    final other = Uri.encodeQueryComponent('https://evil.example/steal');
    expect(await status('/p?u=$other'), 403);
    expect(await status('/p?u=$other&t=${signed.queryParameters['t']}'), 403);
    expect(await status('/x?u=$other'), 403);
  });
}
