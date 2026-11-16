import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/app_log.dart';
import '../widgets/common.dart';

/// Shows the app's log so it can be copied or saved and sent for a fix.
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> {
  String? _text;
  final _scroll = ScrollController();

  /// Chat apps choke on huge pastes; the end of the log matters most.
  static const _copyLimit = 60000;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    var text = await AppLog.read();
    // A long text field is slow to lay out; the end is what matters.
    if (text.length > 200000) {
      text = '…\n${text.substring(text.length - 200000)}';
    }
    if (!mounted) return;
    setState(() => _text = text);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _copy() async {
    final text = _text ?? '';
    final tail = text.length > _copyLimit
        ? '…(bỏ phần đầu)\n${text.substring(text.length - _copyLimit)}'
        : text;
    await Clipboard.setData(ClipboardData(text: tail));
    if (mounted) {
      toast(
        context,
        text.length > _copyLimit
            ? 'Đã sao chép phần cuối nhật ký, dán vào tin nhắn để gửi'
            : 'Đã sao chép, dán vào tin nhắn để gửi',
      );
    }
  }

  Future<void> _save() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = await Directory(
        p.join(docs.path, 'logs'),
      ).create(recursive: true);
      final t = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final name =
          'log-${t.year}${two(t.month)}${two(t.day)}-'
          '${two(t.hour)}${two(t.minute)}.txt';
      await File(p.join(dir.path, name)).writeAsString(_text ?? '');
      if (mounted) {
        toast(
          context,
          'Đã lưu: app Tệp › Trên iPhone › Video Sub › logs › $name',
        );
      }
    } catch (e) {
      if (mounted) toast(context, 'Không lưu được: $e');
    }
  }

  Future<void> _clear() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xoá nhật ký?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Huỷ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xoá'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await AppLog.clear();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final text = _text;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nhật ký lỗi'),
        actions: [
          IconButton(
            tooltip: 'Tải lại',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          IconButton(
            tooltip: 'Lưu thành file',
            icon: const Icon(Icons.save_alt),
            onPressed: text == null ? null : _save,
          ),
          IconButton(
            tooltip: 'Xoá',
            icon: const Icon(Icons.delete_outline),
            onPressed: _clear,
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: text == null || text.isEmpty ? null : _copy,
        icon: const Icon(Icons.copy),
        label: const Text('Sao chép để gửi'),
      ),
      body: text == null
          ? const Center(child: CircularProgressIndicator())
          : text.trim().isEmpty
          ? const Center(child: Text('Chưa có gì trong nhật ký'))
          : Scrollbar(
              controller: _scroll,
              child: SingleChildScrollView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                child: SelectableText(
                  text,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
    );
  }
}
