import 'dart:async';
import 'package:flutter/material.dart';
import '../services/active_work.dart';
import '../services/retained_audio.dart';
import '../services/subtitle_session.dart';
import '../widgets/common.dart';

class RetainedAudioScreen extends StatefulWidget {
  const RetainedAudioScreen({
    super.key,
    this.videoId,
    this.includeHidden = false,
    this.store,
  });
  final String? videoId;
  final bool includeHidden;
  final RetainedAudioStore? store;
  @override
  State<RetainedAudioScreen> createState() => _RetainedAudioScreenState();
}

class _RetainedAudioScreenState extends State<RetainedAudioScreen> {
  RetainedAudioStore get store => widget.store ?? RetainedAudioStore.instance;
  List<RetainedAudio>? _audio;
  String? _error;
  final _busy = <String>{};
  Timer? _refresh;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    if (_loading) return;
    _loading = true;
    try {
      final audio = await store.list(
        includeHidden: widget.includeHidden,
        videoId: widget.videoId,
      );
      if (mounted) {
        setState(() {
          _audio = audio;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = 'Không đọc được kho âm thanh: $e');
    } finally {
      _loading = false;
    }
  }

  Future<void> _confirm(RetainedAudio audio) async {
    final work = ActiveWork.find(audio.videoId);
    final running =
        work != null && work.session.activity != SessionActivity.done;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Xác nhận xóa âm thanh?'),
        content: Text(
          '${audio.title.isEmpty ? 'Video này' : audio.title}\n\n'
          '${running ? 'Tác vụ đang chạy sẽ dừng trước khi xóa âm thanh.\n\n' : ''}'
          'Chỉ xóa âm thanh đã giữ trong app. Phụ đề và video gốc vẫn còn. '
          'Nếu cần nhận dạng lại, app sẽ phải lấy lại âm thanh từ video.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Tiếp tục giữ'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Xác nhận xóa'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy.add(audio.videoId));
    try {
      // Re-read after confirmation: another view may have started a writer.
      await ActiveWork.stop(ActiveWork.find(audio.videoId)?.session);
      await store.deleteConfirmed(audio.videoId);
      if (mounted) toast(context, 'Đã xóa âm thanh sau xác nhận');
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = 'Chưa xóa được âm thanh: $e');
    } finally {
      if (mounted) setState(() => _busy.remove(audio.videoId));
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Âm thanh lưu riêng'),
      actions: [
        IconButton(
          onPressed: _load,
          tooltip: 'Kiểm tra lại',
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Âm thanh được giữ trong vùng riêng của app, kể cả khi làm xong hoặc dừng dịch. '
              'Chỉ xóa khi bạn bấm xác nhận. Không xuất ra Tệp, thư viện nhạc hay bản sao lưu hệ thống.',
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_audio == null && _error == null)
            const Center(child: CircularProgressIndicator()),
          if (_audio?.isEmpty == true)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: Text('Chưa có âm thanh được giữ')),
            ),
          for (final audio in _audio ?? <RetainedAudio>[])
            ListTile(
              leading: const Icon(Icons.lock_outline),
              title: Text(
                audio.title.isEmpty ? 'Video' : audio.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(
                '${(audio.bytes / (1024 * 1024)).toStringAsFixed(1)} MB · ${audio.chunks} đoạn\n'
                '${audio.completed ? 'Đã làm xong' : 'Đang làm hoặc đã dừng'} · giữ đến khi xác nhận',
              ),
              isThreeLine: true,
              trailing: _busy.contains(audio.videoId)
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : TextButton(
                      onPressed: () => _confirm(audio),
                      child: const Text('Xác nhận…'),
                    ),
            ),
        ],
      ),
    ),
  );
}
