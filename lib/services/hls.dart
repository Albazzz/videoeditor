import 'package:http/http.dart' as http;

Map<String, String> _attributes(String line) {
  final out = <String, String>{};
  final body = line.substring(line.indexOf(':') + 1);
  for (final m in RegExp(r'([A-Z0-9-]+)=("[^"]*"|[^,]*)').allMatches(body)) {
    var v = m[2]!;
    if (v.startsWith('"')) v = v.substring(1, v.length - 1);
    out[m[1]!] = v;
  }
  return out;
}

/// Given the text of an HLS playlist, returns the playlist that is cheapest
/// to pull audio from, or null when [playlist] is already a media playlist.
///
/// Handing a master playlist straight to ffmpeg makes it open every quality
/// level, which is far too slow for live subtitles.
Uri? pickAudioPlaylist(String playlist, Uri base, {String language = ''}) {
  final lines = playlist.split(RegExp(r'\r?\n')).map((l) => l.trim()).toList();
  if (!lines.any((l) => l.startsWith('#EXT-X-STREAM-INF'))) return null;

  // Separate audio renditions: tiny, audio-only downloads.
  final audio = <Map<String, String>>[];
  for (final l in lines) {
    if (!l.startsWith('#EXT-X-MEDIA:')) continue;
    final a = _attributes(l);
    if (a['TYPE'] == 'AUDIO' && (a['URI'] ?? '').isNotEmpty) audio.add(a);
  }
  if (audio.isNotEmpty) {
    bool speaks(Map<String, String> a) =>
        language.isNotEmpty &&
        (a['LANGUAGE'] ?? '').toLowerCase().startsWith(language);
    final best = audio.firstWhere(
      speaks,
      orElse: () => audio.firstWhere(
        (a) => a['DEFAULT'] == 'YES',
        orElse: () => audio.first,
      ),
    );
    return base.resolve(best['URI']!);
  }

  // Audio is muxed with the video: take the lightest variant.
  Uri? best;
  var bestRate = -1;
  for (var i = 0; i < lines.length; i++) {
    if (!lines[i].startsWith('#EXT-X-STREAM-INF')) continue;
    final rate = int.tryParse(_attributes(lines[i])['BANDWIDTH'] ?? '') ?? 0;
    final uri = lines
        .skip(i + 1)
        .firstWhere(
          (l) => l.isNotEmpty && !l.startsWith('#'),
          orElse: () => '',
        );
    if (uri.isEmpty) continue;
    if (best == null || rate < bestRate) {
      best = base.resolve(uri);
      bestRate = rate;
    }
  }
  return best;
}

/// Resolves a stream URL to the one ffmpeg should read audio from. Anything
/// that is not an HLS master playlist is returned unchanged.
Future<String> resolveAudioSource(
  String url,
  Map<String, String> headers, {
  String language = '',
}) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !uri.path.toLowerCase().contains('.m3u8')) return url;
  try {
    final res = await http
        .get(uri, headers: headers)
        .timeout(const Duration(seconds: 10));
    if (res.statusCode != 200 || !res.body.contains('#EXTM3U')) return url;
    return pickAudioPlaylist(res.body, uri, language: language)?.toString() ??
        url;
  } catch (_) {
    return url;
  }
}
