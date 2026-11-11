import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/models/cue.dart';
import 'package:video/services/ad_block.dart';
import 'package:video/services/asr_worker.dart';
import 'package:video/services/exporter.dart';
import 'package:video/services/hls.dart';
import 'package:video/services/key_store.dart';
import 'package:video/services/web_video.dart';

void main() {
  const cues = [
    Cue(start: 1, end: 2.5, text: 'Xin chào'),
    Cue(start: 3, end: 5, text: 'Dòng hai'),
    Cue(start: 61.25, end: 63, text: 'Phút sau'),
  ];

  test('SRT round trip keeps times and text', () {
    final srt = toSrt(cues);
    expect(srt, contains('00:00:01,000 --> 00:00:02,500'));
    expect(srt, contains('00:01:01,250 --> 00:01:03,000'));
    final back = parseSrt(srt);
    expect(back.length, 3);
    expect(back[2].start, closeTo(61.25, 0.001));
    expect(back[1].text, 'Dòng hai');
  });

  test('SRT for a trimmed clip is shifted and clipped', () {
    final back = parseSrt(toSrt(cues, from: 4, to: 62));
    expect(back.length, 2);
    expect(back[0].start, 0);
    expect(back[0].end, closeTo(1, 0.001));
    expect(back[1].start, closeTo(57.25, 0.001));
    expect(back[1].end, closeTo(58, 0.001));
  });

  test('cueAt finds the line on screen', () {
    expect(cueAt(cues, 0.5), isNull);
    expect(cueAt(cues, 1.2)!.text, 'Xin chào');
    expect(cueAt(cues, 2.7), isNull);
    expect(cueAt(cues, 62)!.text, 'Phút sau');
    expect(cueAt(const [], 3), isNull);
  });

  test('PBKDF2 matches the RFC 7914 test vector', () {
    final out = pbkdf2('passwd', Uint8List.fromList(utf8.encode('salt')), 1);
    final hex = out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect(
      hex,
      '55ac046e56e3089fec1691c22544b605f94185216dde0465e68b9d57c20dacbc',
    );
  });

  test('WAV reader skips extra chunks', () {
    final b = BytesBuilder()
      ..add(ascii.encode('RIFF'))
      ..add([0, 0, 0, 0])
      ..add(ascii.encode('WAVE'))
      ..add(ascii.encode('fmt '))
      ..add([16, 0, 0, 0])
      ..add(List.filled(16, 0))
      ..add(ascii.encode('LIST'))
      ..add([3, 0, 0, 0, 1, 2, 3, 0]) // odd size + pad byte
      ..add(ascii.encode('data'))
      ..add([4, 0, 0, 0])
      ..add([0x00, 0x40, 0x00, 0xC0]);
    final samples = readPcm16Wav(b.toBytes());
    expect(samples, [0.5, -0.5]);
  });

  test('export arguments combine trim, speed and subtitles', () {
    final args = buildExportArgs(
      input: 'in.mp4',
      output: 'out.mp4',
      from: 5,
      to: 65,
      speed: 2.5,
      srtPath: r'C:\tmp\burn.srt',
      fontsDir: '/tmp/f',
      hardwareEncoder: true,
    );
    final vf = args[args.indexOf('-vf') + 1];
    expect(vf, startsWith(r"subtitles='C\:/tmp/burn.srt':fontsdir='/tmp/f'"));
    expect(vf, endsWith('setpts=PTS/2.500'));
    expect(args[args.indexOf('-af') + 1], 'atempo=2.500');
    expect(args, containsAllInOrder(['-ss', '5.000', '-to', '65.000', '-i']));
    expect(args, contains('h264_videotoolbox'));

    final plain = buildExportArgs(
      input: 'a',
      output: 'b',
      from: 0,
      to: 9,
      speed: 1,
    );
    expect(plain, isNot(contains('-vf')));
    expect(plain, isNot(contains('-af')));
  });

  test('web video report builds request headers', () {
    final v = WebVideo.fromMessage({
      'src': 'https://cdn.example.com/a/master.m3u8',
      't': 12.5,
      'paused': false,
      'dur': 1400,
      'page': 'https://site.example.com/watch/1?x=2',
      'ua': 'UA',
    })!;
    expect(v.playable, isTrue);
    expect(v.headers('a=b'), {
      'User-Agent': 'UA',
      'Referer': 'https://site.example.com/watch/1?x=2',
      'Origin': 'https://site.example.com',
      'Cookie': 'a=b',
    });
    expect(WebVideo.fromMessage({'src': 'blob:x'})!.playable, isFalse);
    expect(WebVideo.fromMessage('nope'), isNull);
  });
  group('HLS audio source', () {
    final base = Uri.parse('https://cdn.example.com/show/master.m3u8?t=1');

    test('prefers a separate audio rendition in the spoken language', () {
      const master = '''
#EXTM3U
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",LANGUAGE="en",DEFAULT=YES,URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Japanese",LANGUAGE="ja-JP",URI="audio/ja.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="s",NAME="x",URI="subs.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=900000,AUDIO="a"
v1/prog.m3u8
''';
      expect(
        pickAudioPlaylist(master, base, language: 'ja').toString(),
        'https://cdn.example.com/show/audio/ja.m3u8',
      );
      expect(
        pickAudioPlaylist(master, base).toString(),
        'https://cdn.example.com/show/audio/en.m3u8',
      );
    });

    test('falls back to the lightest variant when audio is muxed', () {
      const master = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.64002a,mp4a.40.2"
hi/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=400000,RESOLUTION=480x270
/abs/low.m3u8?k=v
#EXT-X-STREAM-INF:BANDWIDTH=1200000
mid/index.m3u8
''';
      expect(
        pickAudioPlaylist(master, base).toString(),
        'https://cdn.example.com/abs/low.m3u8?k=v',
      );
    });

    test('leaves a media playlist alone', () {
      const media = '#EXTM3U\n#EXTINF:6.0,\nseg0.ts\n#EXT-X-ENDLIST\n';
      expect(pickAudioPlaylist(media, base), isNull);
    });
  });
  group('ad blocking', () {
    test('matches ad hosts and their subdomains only', () {
      expect(isAdHost('doubleclick.net'), isTrue);
      expect(isAdHost('Ad.DoubleClick.net'), isTrue);
      expect(isAdHost('notdoubleclick.net'), isFalse);
      expect(isAdHost('doubleclick.net.example.com'), isFalse);
      expect(isAdHost('www.google.com'), isFalse);
      expect(isAdHost('adservice.google.com'), isTrue);
    });

    test('finds the site a host belongs to', () {
      expect(siteOf('player.cdn.example.com'), 'example.com');
      expect(siteOf('example.com'), 'example.com');
      expect(siteOf('phim.example.com.vn'), 'example.com.vn');
      expect(siteOf('www.example.co.uk'), 'example.co.uk');
      expect(siteOf('localhost'), 'localhost');
    });

    test('blocks pop-ups to ad hosts and other sites', () {
      final page = Uri.parse('https://phim.example.com/watch/1');
      bool blocked(String u) => shouldBlockPopup(Uri.parse(u), page);
      expect(blocked('https://www.example.com/tap-2'), isFalse);
      expect(blocked('https://othersite.net/landing'), isTrue);
      expect(blocked('https://x.popads.net/go'), isTrue);
      expect(shouldBlockPopup(null, page), isTrue);
      expect(shouldBlockPopup(Uri.parse('about:blank'), page), isFalse);
    });

    test('url filters match whole domains and avoid alternation', () {
      final filter = adUrlFilter('doubleclick.net');
      expect(filter, isNot(contains('|')));
      final re = RegExp(filter);
      expect(re.hasMatch('https://doubleclick.net/x'), isTrue);
      expect(re.hasMatch('https://ad.g.doubleclick.net:443/x'), isTrue);
      expect(re.hasMatch('https://notdoubleclick.net/x'), isFalse);
      expect(re.hasMatch('https://doubleclickXnet/x'), isFalse);
      expect(re.hasMatch('https://example.com/?u=doubleclick.net/'), isFalse);
    });

    test('builds one rule per domain plus the hiding rule', () {
      expect(kAdDomains.toSet().length, kAdDomains.length);
      final rules = adBlockRules();
      expect(rules.length, kAdDomains.length + 1);
      expect(rules.last.action.selector, contains('.adsbygoogle'));
    });
  });
}
