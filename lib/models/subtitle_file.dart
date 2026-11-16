import 'dart:convert';
import 'dart:typed_data';

import 'cue.dart';

/// Languages the on-device translator can turn into Vietnamese, by code.
const kSubtitleLanguages = <String, String>{
  'en': 'Tiếng Anh',
  'id': 'Tiếng Indonesia',
  'th': 'Tiếng Thái',
  'ja': 'Tiếng Nhật',
  'zh': 'Tiếng Trung',
  'ko': 'Tiếng Hàn',
  'ms': 'Tiếng Mã Lai',
  'tl': 'Tiếng Tagalog (Philippines)',
  'hi': 'Tiếng Hindi',
  'es': 'Tiếng Tây Ban Nha',
  'pt': 'Tiếng Bồ Đào Nha',
  'fr': 'Tiếng Pháp',
  'de': 'Tiếng Đức',
  'it': 'Tiếng Ý',
  'ru': 'Tiếng Nga',
  'uk': 'Tiếng Ukraina',
  'ar': 'Tiếng Ả Rập',
  'tr': 'Tiếng Thổ Nhĩ Kỳ',
  'fa': 'Tiếng Ba Tư',
  'he': 'Tiếng Do Thái',
  'el': 'Tiếng Hy Lạp',
  'pl': 'Tiếng Ba Lan',
  'nl': 'Tiếng Hà Lan',
  'sv': 'Tiếng Thuỵ Điển',
  'no': 'Tiếng Na Uy',
  'da': 'Tiếng Đan Mạch',
  'fi': 'Tiếng Phần Lan',
  'cs': 'Tiếng Séc',
  'sk': 'Tiếng Slovakia',
  'hu': 'Tiếng Hungary',
  'ro': 'Tiếng Romania',
  'bg': 'Tiếng Bulgaria',
  'hr': 'Tiếng Croatia',
  'sl': 'Tiếng Slovenia',
  'lt': 'Tiếng Litva',
  'lv': 'Tiếng Latvia',
  'et': 'Tiếng Estonia',
  'be': 'Tiếng Belarus',
  'mk': 'Tiếng Macedonia',
  'sq': 'Tiếng Albania',
  'ka': 'Tiếng Gruzia',
  'bn': 'Tiếng Bengal',
  'ta': 'Tiếng Tamil',
  'te': 'Tiếng Telugu',
  'kn': 'Tiếng Kannada',
  'mr': 'Tiếng Marathi',
  'gu': 'Tiếng Gujarat',
  'ur': 'Tiếng Urdu',
  'sw': 'Tiếng Swahili',
  'af': 'Tiếng Afrikaans',
  'ca': 'Tiếng Catalan',
  'gl': 'Tiếng Galicia',
  'cy': 'Tiếng Wales',
  'ga': 'Tiếng Ireland',
  'is': 'Tiếng Iceland',
  'mt': 'Tiếng Malta',
  'ht': 'Tiếng Haiti',
  'eo': 'Quốc tế ngữ',
  'vi': 'Tiếng Việt (không cần dịch)',
};

/// Turns the raw bytes of a subtitle file into text. Handles UTF-8, UTF-16
/// (with a byte-order mark), Thai TIS-620 / Windows-874, and falls back to
/// Windows-1252 for other old Latin files.
String decodeSubtitleBytes(Uint8List bytes) {
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    return utf8.decode(bytes.sublist(3), allowMalformed: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes.sublist(2), Endian.little);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes.sublist(2), Endian.big);
  }
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Not UTF-8: an older single-byte encoding.
  }
  // Thai text is almost all high bytes; Latin text only has a few accents.
  var thai = 0, high = 0, ascii = 0;
  for (final b in bytes) {
    if (b >= 0x80) high++;
    if (b >= 0xA1 && b <= 0xFB) thai++;
    if ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A) ascii++;
  }
  if (high > 0 && thai / high > 0.9 && high > ascii) {
    return String.fromCharCodes([
      for (final b in bytes) b >= 0xA1 && b <= 0xFB ? b + 0x0D60 : b,
    ]);
  }
  return String.fromCharCodes([for (final b in bytes) _cp1252[b] ?? b]);
}

/// Windows-1252 differs from Latin-1 only in 0x80-0x9F: curly quotes,
/// dashes, ellipsis and a few letters old subtitle files are full of.
const _cp1252 = <int, int>{
  0x80: 0x20AC,
  0x82: 0x201A,
  0x83: 0x0192,
  0x84: 0x201E,
  0x85: 0x2026,
  0x86: 0x2020,
  0x87: 0x2021,
  0x88: 0x02C6,
  0x89: 0x2030,
  0x8A: 0x0160,
  0x8B: 0x2039,
  0x8C: 0x0152,
  0x8E: 0x017D,
  0x91: 0x2018,
  0x92: 0x2019,
  0x93: 0x201C,
  0x94: 0x201D,
  0x95: 0x2022,
  0x96: 0x2013,
  0x97: 0x2014,
  0x98: 0x02DC,
  0x99: 0x2122,
  0x9A: 0x0161,
  0x9B: 0x203A,
  0x9C: 0x0153,
  0x9E: 0x017E,
  0x9F: 0x0178,
};

String _utf16(Uint8List bytes, Endian endian) {
  final view = ByteData.sublistView(bytes);
  final units = [
    for (var i = 0; i + 1 < bytes.length; i += 2) view.getUint16(i, endian),
  ];
  return String.fromCharCodes(units);
}

/// Removes styling: HTML-like tags, ASS override blocks, ASS line breaks.
String cleanCueText(String text) => text
    .replaceAll(RegExp(r'\{[^}]*\}'), '')
    .replaceAll(RegExp(r'\\[Nn]'), '\n')
    .replaceAll(r'\h', ' ')
    .replaceAll(RegExp(r'<[^>]*>'), '')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&')
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty)
    .join('\n');

double? _assTime(String s) {
  final m = RegExp(r'(\d+):(\d{1,2}):(\d{1,2})[.,](\d{1,3})').firstMatch(s);
  if (m == null) return null;
  final frac = m[4]!;
  return int.parse(m[1]!) * 3600 +
      int.parse(m[2]!) * 60 +
      int.parse(m[3]!) +
      int.parse(frac) /
          (frac.length == 1
              ? 10
              : frac.length == 2
              ? 100
              : 1000);
}

List<Cue> _parseAss(String content) {
  final cues = <Cue>[];
  var fields = <String>[
    'layer', 'start', 'end', 'style', 'name', //
    'marginl', 'marginr', 'marginv', 'effect', 'text',
  ];
  var inEvents = false;
  for (final raw in content.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.startsWith('[')) {
      inEvents = line.toLowerCase() == '[events]';
      continue;
    }
    if (!inEvents) continue;
    final lower = line.toLowerCase();
    if (lower.startsWith('format:')) {
      fields = line
          .substring(7)
          .split(',')
          .map((f) => f.trim().toLowerCase())
          .toList();
      continue;
    }
    if (!lower.startsWith('dialogue:')) continue;
    final body = line.substring(line.indexOf(':') + 1);
    // Only the last field (the text) may itself contain commas.
    final parts = <String>[];
    var rest = body;
    for (var i = 0; i < fields.length - 1; i++) {
      final at = rest.indexOf(',');
      if (at < 0) break;
      parts.add(rest.substring(0, at).trim());
      rest = rest.substring(at + 1);
    }
    parts.add(rest);
    if (parts.length != fields.length) continue;
    final start = _assTime(parts[fields.indexOf('start')]);
    final end = _assTime(parts[fields.indexOf('end')]);
    final text = cleanCueText(parts[fields.indexOf('text')]);
    if (start == null || end == null || text.isEmpty || end <= start) continue;
    cues.add(Cue(start: start, end: end, text: text));
  }
  return cues;
}

/// Reads SRT, WebVTT or ASS/SSA. Lines come back cleaned and sorted.
List<Cue> parseSubtitleFile(String content) {
  final text = content.replaceAll('﻿', '');
  final isAss =
      text.contains(RegExp(r'^\s*\[Events\]', multiLine: true)) &&
      text.contains(RegExp(r'^\s*Dialogue:', multiLine: true));
  final raw = isAss ? _parseAss(text) : parseSrt(text);
  final cues = [
    for (final c in raw)
      if (cleanCueText(c.text) case final t
          when t.isNotEmpty && c.end > c.start)
        Cue(start: c.start, end: c.end, text: t),
  ]..sort((a, b) => a.start.compareTo(b.start));
  return cues;
}

const _latinHints = <String, List<String>>{
  'vi': ['không', 'của', 'và', 'là', 'tôi', 'được', 'này', 'anh', 'em'],
  'id': [
    'yang',
    'dan',
    'tidak',
    'aku',
    'kamu',
    'ini',
    'itu',
    'apa',
    'ada',
    'saya',
    'dia',
    'akan',
    'sudah',
    'kita',
    'tapi',
  ],
  'ms': ['tidak', 'saya', 'awak', 'kau', 'boleh', 'sahaja', 'ialah'],
  'tl': ['ang', 'ng', 'mga', 'ako', 'ka', 'sa', 'hindi', 'ikaw', 'siya'],
  'en': ['the', 'you', 'and', 'is', 'what', 'to', 'it', 'that', 'are', 'i'],
  'es': ['que', 'el', 'los', 'por', 'está', 'qué', 'pero', 'una', 'muy'],
  'pt': ['não', 'você', 'é', 'uma', 'isso', 'está', 'para', 'com', 'eu'],
  'fr': ['le', 'les', 'est', 'vous', 'pas', 'je', 'une', 'et', 'c\'est'],
  'de': ['und', 'ich', 'nicht', 'das', 'ist', 'du', 'die', 'der', 'sie'],
  'it': ['che', 'non', 'il', 'sono', 'per', 'una', 'è', 'questo'],
};

/// Best guess of the language of [lines], as a code from
/// [kSubtitleLanguages]. The user can always correct it.
String guessLanguage(Iterable<String> lines) {
  final sample = lines.take(400).join('\n');
  int count(int from, int to) =>
      sample.runes.where((r) => r >= from && r <= to).length;
  final scripts = <String, int>{
    'th': count(0x0E00, 0x0E7F),
    'ja': count(0x3040, 0x30FF),
    'ko': count(0xAC00, 0xD7AF) + count(0x1100, 0x11FF),
    'zh': count(0x4E00, 0x9FFF),
    'ru': count(0x0400, 0x04FF),
    'ar': count(0x0600, 0x06FF),
    'he': count(0x0590, 0x05FF),
    'el': count(0x0370, 0x03FF),
    'hi': count(0x0900, 0x097F),
  };
  // Kana marks Japanese even when kanji outnumber it.
  if (scripts['ja']! > 0 && scripts['ja']! * 5 >= scripts['zh']!) {
    scripts['ja'] = scripts['ja']! + scripts['zh']!;
  }
  final best = scripts.entries.reduce((a, b) => b.value > a.value ? b : a);
  final letters = sample.runes.where((r) => r > 0x40).length;
  if (best.value > 0 && best.value * 4 > letters) return best.key;

  // Latin script: Vietnamese letters first, then common words.
  if (RegExp(
        '[ơưđăạảấầẩẫậắằẳẵặẹẻẽếềểễệỉịọỏốồổỗộớờởỡợụủứừửữựỳỵỷỹ]',
      ).allMatches(sample.toLowerCase()).length >
      sample.length / 200) {
    return 'vi';
  }
  final words = RegExp(
    r"[\p{L}']+",
    unicode: true,
  ).allMatches(sample.toLowerCase()).map((m) => m[0]!).toList();
  var bestLang = 'en';
  var bestScore = 0;
  for (final e in _latinHints.entries) {
    final hints = e.value.toSet();
    final score = words.where(hints.contains).length;
    if (score > bestScore) {
      bestScore = score;
      bestLang = e.key;
    }
  }
  return bestLang;
}
