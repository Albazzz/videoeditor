import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

class VercelCredits {
  const VercelCredits({
    required this.balance,
    required this.totalUsed,
    this.hasTokenPass = false,
    this.tokenPassRemaining,
    this.tokenPassResetsAt,
  });

  final double balance, totalUsed;
  final bool hasTokenPass;
  final double? tokenPassRemaining;
  final DateTime? tokenPassResetsAt;

  factory VercelCredits.fromJson(Map<String, dynamic> json) {
    double amount(Object? value) {
      final parsed = value is num
          ? value.toDouble()
          : value is String
          ? double.tryParse(value)
          : null;
      if (parsed == null || !parsed.isFinite) {
        throw const FormatException('Invalid credit amount');
      }
      return parsed;
    }

    final pass = json['token_pass'];
    if (pass != null && pass is! Map) {
      throw const FormatException('Invalid Token Pass');
    }
    final remaining = pass is Map ? pass['remaining'] : null;
    return VercelCredits(
      balance: amount(json['balance']),
      totalUsed: amount(json['total_used']),
      hasTokenPass: pass != null,
      tokenPassRemaining: remaining == null ? null : amount(remaining),
      tokenPassResetsAt: pass is Map && pass['resets_at'] is String
          ? DateTime.tryParse(pass['resets_at'] as String)
          : null,
    );
  }
}

class VercelCreditsError implements Exception {
  const VercelCreditsError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read-only balance lookup. No inference request or credentials in logs.
class VercelCreditsApi {
  static final endpoint = Uri.parse('https://ai-gateway.vercel.sh/v1/credits');

  static Future<VercelCredits> fetch(
    String apiKey, {
    http.Client? client,
  }) async {
    final key = apiKey.trim();
    if (key.isEmpty) {
      throw const VercelCreditsError(
        'Thêm key Vercel AI Gateway để xem số dư.',
      );
    }
    final connection = client ?? http.Client();
    try {
      return await (() async {
        final response = await connection.send(
          http.Request('GET', endpoint)
            ..followRedirects = false
            ..headers.addAll({
              'Authorization': 'Bearer $key',
              'Accept': 'application/json',
            }),
        );
        if (response.statusCode != 200) {
          // Never echo server error bodies: they can include the supplied key.
          throw VercelCreditsError(switch (response.statusCode) {
            401 =>
              'Key Vercel không hợp lệ hoặc đã hết hạn. Hãy kiểm tra lại key.',
            403 => 'Key này không được phép xem số dư AI Gateway.',
            429 => 'Vercel đang giới hạn lượt kiểm tra. Hãy thử lại sau.',
            _ => 'Chưa đọc được số dư từ Vercel (HTTP ${response.statusCode}).',
          });
        }
        final bytes = <int>[];
        await for (final part in response.stream) {
          if (bytes.length + part.length > 64 * 1024) {
            throw const FormatException('Credit response too large');
          }
          bytes.addAll(part);
        }
        final json = jsonDecode(utf8.decode(bytes));
        if (json is! Map<String, dynamic>) throw const FormatException();
        return VercelCredits.fromJson(json);
      })().timeout(const Duration(seconds: 15));
    } on VercelCreditsError {
      rethrow;
    } on TimeoutException {
      throw const VercelCreditsError('Kiểm tra số dư quá lâu. Hãy thử lại.');
    } on FormatException {
      throw const VercelCreditsError(
        'Vercel trả về số dư không hợp lệ. Hãy thử lại.',
      );
    } catch (_) {
      throw const VercelCreditsError(
        'Không kết nối được Vercel. Kiểm tra mạng rồi thử lại.',
      );
    } finally {
      if (client == null) connection.close();
    }
  }
}
