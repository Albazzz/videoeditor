import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class NetResponse {
  const NetResponse(this.status, this.bytes, this.headers, [this.url]);
  final Uri? url;
  final int status;
  final Uint8List bytes;
  final Map<String, String> headers;
}

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
    final res = await fetch(url, headers, client: client, timeout: timeout);
    return (res.status, res.bytes);
  }

  static Future<NetResponse> fetch(
    Uri url,
    Map<String, String> headers, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 30),
    int? maxBytes,
  }) async {
    for (var attempt = 0; ; attempt++) {
      try {
        final res = await _fetch(
          url,
          headers,
          client: client,
          timeout: timeout,
          maxBytes: maxBytes,
        );
        if (attempt >= 2 ||
            !{408, 429, 500, 502, 503, 504}.contains(res.status)) {
          return res;
        }
      } on Exception {
        if (attempt >= 2) rethrow;
      }
      await Future<void>.delayed(Duration(milliseconds: 250 * (attempt + 1)));
    }
  }

  static Map<String, String> headersFor(
    Uri origin,
    Uri target,
    Map<String, String> headers,
  ) {
    if (target.isScheme('http') || target.isScheme('https')) {
      if (origin.origin == target.origin) return headers;
    }
    return {
      for (final e in headers.entries)
        if (!{
          'cookie',
          'authorization',
          'proxy-authorization',
          'referer',
        }.contains(e.key.toLowerCase()))
          e.key: e.value
        else if (e.key.toLowerCase() == 'referer' &&
            Uri.tryParse(e.value)?.hasAuthority == true &&
            (e.value.startsWith('https://') || e.value.startsWith('http://')))
          e.key: '${Uri.parse(e.value).origin}/',
    };
  }

  static Future<NetResponse> _fetch(
    Uri url,
    Map<String, String> headers, {
    http.Client? client,
    required Duration timeout,
    int? maxBytes,
  }) async {
    var target = url;
    var outgoing = headers;
    for (var hops = 0; hops <= 5; hops++) {
      if (!target.isScheme('http') && !target.isScheme('https')) {
        throw const HttpException('Địa chỉ luồng không hợp lệ');
      }
      final response = await _single(
        target,
        outgoing,
        client: client,
        timeout: timeout,
        maxBytes: maxBytes ?? 32 * 1024 * 1024,
      );
      final location = response.headers['location'];
      if (!{301, 302, 303, 307, 308}.contains(response.status) ||
          location == null) {
        return NetResponse(
          response.status,
          response.bytes,
          response.headers,
          target,
        );
      }
      final next = target.resolve(location);
      outgoing = headersFor(target, next, outgoing);
      target = next;
    }
    throw const HttpException('Quá nhiều lần chuyển hướng');
  }

  static Future<NetResponse> _single(
    Uri url,
    Map<String, String> headers, {
    http.Client? client,
    required Duration timeout,
    int? maxBytes,
  }) async {
    if (_native && client == null) {
      try {
        final res = await _channel
            .invokeMapMethod<String, Object?>('get', {
              'url': url.toString(),
              'headers': headers,
              'timeout': timeout.inSeconds,
              'maxBytes': ?maxBytes,
            })
            // iOS ends a request that stops receiving for [timeout]; a slow
            // piece that keeps arriving is allowed to finish.
            .timeout(timeout * 4 + const Duration(seconds: 5));
        final body = res?['body'];
        return NetResponse(
          (res?['status'] as int?) ?? 0,
          body is Uint8List ? body : Uint8List(0),
          {
            for (final e in ((res?['headers'] as Map?) ?? {}).entries)
              '${e.key}'.toLowerCase(): '${e.value}',
          },
        );
      } on MissingPluginException {
        _native = false;
      } on PlatformException catch (e) {
        throw HttpException(e.message ?? e.code, uri: url);
      }
    }
    final c = client ?? http.Client();
    try {
      return await (() async {
        final res = await c.send(
          http.Request('GET', url)
            ..followRedirects = false
            ..headers.addAll(headers),
        );
        if (maxBytes != null && (res.contentLength ?? 0) > maxBytes) {
          throw const HttpException('Máy chủ bỏ qua giới hạn tải từng phần');
        }
        final body = BytesBuilder(copy: false);
        await for (final part in res.stream) {
          if (maxBytes != null && body.length + part.length > maxBytes) {
            throw const HttpException(
              'Dữ liệu video vượt giới hạn tải từng phần',
            );
          }
          body.add(part);
        }
        return NetResponse(res.statusCode, body.takeBytes(), res.headers);
      })().timeout(timeout);
    } finally {
      if (client == null) c.close();
    }
  }
}
