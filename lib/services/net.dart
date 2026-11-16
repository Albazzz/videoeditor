import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Downloads through iOS's own network stack (URLSession, as Safari),
/// with the Dart client as the fallback elsewhere.
///
/// Some video servers cut off any client whose TLS handshake does not look
/// like a browser's: both Dart's client and ffmpeg were reset by eporner's
/// servers while the web view played the same address.
class Net {
  static const _channel = MethodChannel('vsub/net');
  static bool _native = Platform.isIOS;

  static Future<(int, Uint8List)> get(
    Uri url,
    Map<String, String> headers, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_native && client == null) {
      try {
        final res = await _channel
            .invokeMapMethod<String, Object?>('get', {
              'url': url.toString(),
              'headers': headers,
              'timeout': timeout.inSeconds,
            })
            .timeout(timeout + const Duration(seconds: 5));
        final body = res?['body'];
        return (
          (res?['status'] as int?) ?? 0,
          body is Uint8List ? body : Uint8List(0),
        );
      } on MissingPluginException {
        _native = false;
      } on PlatformException catch (e) {
        throw HttpException(e.message ?? e.code, uri: url);
      }
    }
    final c = client ?? http.Client();
    try {
      final res = await c.get(url, headers: headers).timeout(timeout);
      return (res.statusCode, res.bodyBytes);
    } finally {
      if (client == null) c.close();
    }
  }
}
