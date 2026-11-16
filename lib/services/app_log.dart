import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// The app's diary: what it did and what went wrong, kept in a file the
/// user can copy from Settings and send when something breaks.
///
/// Lines are written synchronously and flushed, so whatever happened just
/// before a native crash is still there at the next launch.
class AppLog {
  static String? _path;

  /// Kept below this; trimmed at launch.
  static const _maxBytes = 600 * 1024;

  /// What the native crash handler (AppDelegate.swift) recorded last run.
  static String? previousNativeCrash;

  static String? get path => _path;

  static Future<void> init() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'app_log.txt'));
      _path = file.path;
      if (await file.exists() && await file.length() > _maxBytes) {
        final text = await file.readAsString();
        await file.writeAsString(text.substring(text.length - _maxBytes ~/ 2));
      }
      final native = File(p.join(dir.path, 'native_crash.log'));
      if (await native.exists()) {
        final text = (await native.readAsString()).trim();
        await native.writeAsString('');
        if (text.isNotEmpty) previousNativeCrash = text;
      }
    } catch (_) {}

    _line('');
    _line(
      '===== Mở app ${DateTime.now().toIso8601String()} · '
      '${Platform.operatingSystem} ${Platform.operatingSystemVersion} =====',
    );
    final native = previousNativeCrash;
    if (native != null) {
      e('văng', 'Lần trước app văng vì lỗi native:\n$native');
    }

    final flutterError = FlutterError.onError;
    FlutterError.onError = (details) {
      e('flutter', details.exceptionAsString(), details.stack);
      flutterError?.call(details);
    };
    PlatformDispatcher.instance.onError = (error, stack) {
      e('dart', error, stack);
      return true;
    };
    final print = debugPrint;
    debugPrint = (message, {wrapWidth}) {
      if (message != null) i('print', message);
      print(message, wrapWidth: wrapWidth);
    };
  }

  /// Something worth knowing happened.
  static void i(String tag, String message) =>
      _line('${_now()} [$tag] $message');

  /// Something went wrong.
  static void e(String tag, Object error, [StackTrace? stack]) {
    final trace = stack == null
        ? ''
        : '\n${stack.toString().split('\n').take(12).join('\n')}';
    _line('${_now()} [$tag] LỖI: $error$trace');
  }

  /// A URL without its query string, which often holds access tokens.
  static String url(String u) {
    final q = u.indexOf('?');
    final short = q < 0 ? u : '${u.substring(0, q)}?…';
    return short.length > 200 ? '${short.substring(0, 200)}…' : short;
  }

  static Future<String> read() async {
    final path = _path;
    if (path == null) return '';
    try {
      return await File(path).readAsString();
    } catch (_) {
      return '';
    }
  }

  static Future<void> clear() async {
    final path = _path;
    if (path == null) return;
    try {
      await File(path).writeAsString('');
    } catch (_) {}
  }

  static String _now() {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}.'
        '${t.millisecond.toString().padLeft(3, '0')}';
  }

  static void _line(String line) {
    final path = _path;
    if (path == null) return;
    try {
      File(
        path,
      ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
