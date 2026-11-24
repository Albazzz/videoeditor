import 'package:flutter/material.dart';

import '../services/vercel_credits.dart';

class VercelCreditsPanel extends StatefulWidget {
  const VercelCreditsPanel({super.key, required this.apiKey, this.fetch});
  final String apiKey;
  final Future<VercelCredits> Function(String key)? fetch;

  @override
  State<VercelCreditsPanel> createState() => _VercelCreditsPanelState();
}

class _VercelCreditsPanelState extends State<VercelCreditsPanel> {
  VercelCredits? _credits;
  DateTime? _updated;
  String? _error;
  bool _loading = false;
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void didUpdateWidget(covariant VercelCreditsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey) {
      _credits = null;
      _updated = null;
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final request = ++_request;
    final key = widget.apiKey;
    setState(() {
      _loading = key.trim().isNotEmpty;
      _error = null;
    });
    if (!_loading) return;
    try {
      final credits = await (widget.fetch ?? VercelCreditsApi.fetch)(key);
      if (!mounted || request != _request) return;
      setState(() {
        _credits = credits;
        _updated = DateTime.now();
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(
        () => _error = e is VercelCreditsError
            ? e.message
            : 'Chưa đọc được số dư. Hãy thử lại.',
      );
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  static String _usd(double value) {
    if (value != 0 && value.abs() < 0.0001) {
      return value > 0 ? '<0.0001 USD' : '−<0.0001 USD';
    }
    return '${value.toStringAsFixed(4)} USD';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final credits = _credits;
    final updated = _updated;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_balance_wallet_outlined, size: 22),
              const SizedBox(width: 12),
              Expanded(
                child: Text('Số dư Vercel', style: theme.textTheme.titleMedium),
              ),
              IconButton(
                tooltip: _error == null ? 'Cập nhật số dư' : 'Thử lại số dư',
                onPressed: _loading || widget.apiKey.trim().isEmpty
                    ? null
                    : _refresh,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh),
              ),
            ],
          ),
          if (widget.apiKey.trim().isEmpty)
            const Text('Thêm key Vercel AI Gateway để xem số dư.')
          else if (credits != null) ...[
            Text(
              '${_error == null ? 'Còn lại' : 'Số dư lần cập nhật trước'}: ${_usd(credits.balance)}',
              style: theme.textTheme.titleLarge,
            ),
            Text('Tổng đã dùng: ${_usd(credits.totalUsed)}'),
            if (credits.hasTokenPass) ...[
              Text(
                credits.tokenPassRemaining == null
                    ? 'Token Pass: tạm thời chưa đọc được số dư'
                    : 'Token Pass còn lại: ${_usd(credits.tokenPassRemaining!)}',
              ),
              if (credits.tokenPassResetsAt case final DateTime reset)
                Text('Token Pass cấp lại lúc ${_date(reset.toLocal())}'),
            ],
          ] else if (_loading)
            const Text('Đang kiểm tra số dư…'),
          if (updated != null)
            Text(
              'Cập nhật lúc ${_date(updated)}',
              style: theme.textTheme.bodySmall,
            ),
          if (_error != null) ...[
            const SizedBox(height: 4),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
          const SizedBox(height: 4),
          Text(
            'Số dư chung của nhóm Vercel gắn với key. Token Pass được hiển thị riêng nếu có.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  String _date(DateTime time) =>
      '${time.day}/${time.month}/${time.year} '
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}:'
      '${time.second.toString().padLeft(2, '0')}';
}
