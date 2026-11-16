import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:video/models/subtitle_file.dart';
import 'package:video/models/cue.dart';
import 'package:video/widgets/subtitle_import.dart';

void main() {
  group('reading files', () {
    test('SRT with styling tags and CRLF', () {
      const srt =
          '1\r\n00:00:01,000 --> 00:00:03,500\r\n<i>Apa kabar?</i>\r\n'
          '<font color="#ff0">Baik.</font>\r\n\r\n'
          '2\r\n00:01:02,250 --> 00:01:04,000\r\n{\\an8}Terima kasih\r\n';
      final cues = parseSubtitleFile(srt);
      expect(cues.length, 2);
      expect(cues[0].text, 'Apa kabar?\nBaik.');
      expect(cues[0].end, 3.5);
      expect(cues[1].start, closeTo(62.25, 0.001));
      expect(cues[1].text, 'Terima kasih');
    });

    test('WebVTT without hours, with ids and settings', () {
      const vtt =
          'WEBVTT\n\nNOTE made by hand\n\nintro\n'
          '00:05.000 --> 00:07.250 align:center line:90%\nสวัสดีครับ\n\n'
          '01:00:00.000 --> 01:00:02.000\n<v Bob>See you</v>\n';
      final cues = parseSubtitleFile(vtt);
      expect(cues.length, 2);
      expect(cues[0].start, 5);
      expect(cues[0].end, 7.25);
      expect(cues[0].text, 'สวัสดีครับ');
      expect(cues[1].start, 3600);
      expect(cues[1].text, 'See you');
    });

    test('ASS with commas in the text, line breaks and overrides', () {
      const ass = '''
[Script Info]
Title: test

[V4+ Styles]
Format: Name, Fontname
Style: Default,Arial

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:02.50,0:00:04.00,Default,,0,0,0,,{\\i1}Hola,{\\i0} ¿cómo estás?\\NBien
Comment: 0,0:00:05.00,0:00:06.00,Default,,0,0,0,,not shown
Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,Primero
''';
      final cues = parseSubtitleFile(ass);
      expect(cues.length, 2);
      expect(cues[0].text, 'Primero');
      expect(cues[1].start, 2.5);
      expect(cues[1].end, 4);
      expect(cues[1].text, 'Hola, ¿cómo estás?\nBien');
    });

    test('files without subtitle lines give nothing', () {
      expect(parseSubtitleFile('just some text\nno times'), isEmpty);
    });
  });

  group('text encodings', () {
    test('UTF-8 with and without BOM', () {
      final plain = Uint8List.fromList(utf8.encode('Xin chào ภาษาไทย'));
      expect(decodeSubtitleBytes(plain), 'Xin chào ภาษาไทย');
      final bom = Uint8List.fromList([0xEF, 0xBB, 0xBF, ...plain]);
      expect(decodeSubtitleBytes(bom), 'Xin chào ภาษาไทย');
    });

    test('UTF-16 little and big endian', () {
      const text = '日本語 OK';
      final le = <int>[0xFF, 0xFE];
      final be = <int>[0xFE, 0xFF];
      for (final u in text.codeUnits) {
        le.addAll([u & 0xFF, u >> 8]);
        be.addAll([u >> 8, u & 0xFF]);
      }
      expect(decodeSubtitleBytes(Uint8List.fromList(le)), text);
      expect(decodeSubtitleBytes(Uint8List.fromList(be)), text);
    });

    test('Thai TIS-620 / Windows-874', () {
      // "สวัสดี" in TIS-620.
      final bytes = Uint8List.fromList([0xCA, 0xC7, 0xD1, 0xCA, 0xB4, 0xD5]);
      expect(decodeSubtitleBytes(bytes), 'สวัสดี');
    });

    test('old Latin files fall back to Windows-1252', () {
      final bytes = Uint8List.fromList([0x63, 0x61, 0x66, 0xE9]); // café
      expect(decodeSubtitleBytes(bytes), 'café');
      final quotes = Uint8List.fromList([0x93, 0x48, 0x69, 0x94, 0x85, 0x96]);
      expect(decodeSubtitleBytes(quotes), '“Hi”…–');
    });
  });

  group('language guess', () {
    test('by script', () {
      expect(guessLanguage(['ฉันรักคุณ', 'ไปไหนมา']), 'th');
      expect(guessLanguage(['今日はいい天気ですね', '何をしているの？']), 'ja');
      expect(guessLanguage(['你在做什么？', '我们走吧']), 'zh');
      expect(guessLanguage(['안녕하세요', '어디 가요?']), 'ko');
      expect(guessLanguage(['Что ты делаешь?']), 'ru');
    });

    test('Latin languages by common words', () {
      expect(
        guessLanguage([
          'Aku tidak tahu apa yang kamu maksud.',
          'Ini bukan salahku, dia yang mulai.',
        ]),
        'id',
      );
      expect(
        guessLanguage(['What are you doing here?', 'I told you to stay.']),
        'en',
      );
      expect(
        guessLanguage(['Anh không biết em đang ở đâu.', 'Tôi về nhà rồi.']),
        'vi',
      );
      expect(
        guessLanguage(['¿Qué estás haciendo? No es muy bueno para el']),
        'es',
      );
    });

    test('every guess is a language the picker offers', () {
      for (final lines in [
        ['ฉัน'],
        ['日本'],
        ['hello'],
        ['שלום'],
        ['नमस्ते'],
        ['Γεια'],
      ]) {
        expect(kSubtitleLanguages.keys, contains(guessLanguage(lines)));
      }
    });
  });

  test('shifting moves lines and drops ones pushed before zero', () {
    const cues = [
      Cue(start: 0.2, end: 0.4, text: 'a'),
      Cue(start: 1, end: 2, text: 'b', source: 'B'),
    ];
    final earlier = shiftCues(cues, -0.5);
    expect(earlier.length, 1);
    expect(earlier.single.start, 0.5);
    expect(earlier.single.source, 'B');
    final later = shiftCues(cues, 1.5);
    expect(later.first.start, closeTo(1.7, 1e-9));
    expect(later.last.end, 3.5);
  });
}
