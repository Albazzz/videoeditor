import 'package:flutter_test/flutter_test.dart';
import 'package:video/services/web_video.dart';

WebVideo report(
  String src, {
  int area = 0,
  bool paused = false,
  bool muted = false,
  double duration = 0,
}) => WebVideo.fromMessage({
  'src': src,
  't': 10,
  'paused': paused,
  'dur': duration,
  'page': 'https://site.example/',
  'ua': 'x',
  'area': area,
  'muted': muted,
})!;

void main() {
  // Like the page in the user's log: the film plus muted, looping adverts
  // in other frames, all reporting at once.
  final film = report(
    'https://fc2stream.example/stream/master.m3u8',
    area: 390 * 220,
    duration: 7200,
  );
  final ads = [
    report(
      'https://ads.example/1_240p.m3u8',
      area: 300 * 250,
      muted: true,
      duration: 30,
    ),
    report(
      'https://ads.example/2_480p.m3u8',
      area: 0,
      muted: true,
      duration: 15,
    ),
    report('https://ads.example/3_240p.m3u8', area: 320 * 50, muted: true),
    report(
      'https://site.example/preview_240p.m3u8',
      area: 390 * 220,
      muted: true,
      duration: 60,
    ),
  ];

  test('the film is chosen over adverts, whatever order they report in', () {
    expect(WebVideo.main([...ads, film])!.src, film.src);
    expect(WebVideo.main([film, ...ads])!.src, film.src);
  });

  test('a paused film still beats playing adverts', () {
    final paused = report(
      film.src,
      area: 390 * 220,
      duration: 7200,
      paused: true,
    );
    expect(WebVideo.main([...ads, paused])!.src, film.src);
  });

  test('the video being subtitled stays chosen', () {
    final bigAd = report(
      'https://ads.example/big.m3u8',
      area: 400 * 800,
      duration: 600,
    );
    expect(WebVideo.main([film, bigAd])!.src, bigAd.src);
    expect(WebVideo.main([film, bigAd], keep: film.src)!.src, film.src);
  });

  test('older pages without size reports still work', () {
    final old = WebVideo.fromMessage({
      'src': 'https://a.example/v.mp4',
      't': 1,
    })!;
    expect(old.area, 0);
    expect(WebVideo.main([old])!.src, old.src);
  });
}
