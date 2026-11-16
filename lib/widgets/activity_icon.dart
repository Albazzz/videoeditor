import 'dart:async';

import 'package:flutter/material.dart';

import '../services/subtitle_session.dart';

/// Shows at a glance whether subtitles are being made: a turning circle
/// while work moves on, an hourglass when nothing has happened for 20
/// seconds, pause, done or error. Tapping explains the icon.
class ActivityIcon extends StatefulWidget {
  const ActivityIcon({super.key, required this.session, this.size = 18});
  final SubtitleSession session;
  final double size;

  @override
  State<ActivityIcon> createState() => _ActivityIconState();
}

class _ActivityIconState extends State<ActivityIcon> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    // "Nothing for 20 s" depends on the clock, not only on events.
    _tick = Timer.periodic(const Duration(seconds: 2), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick.cancel();
    super.dispose();
  }

  static String describe(SessionActivity a) => switch (a) {
    SessionActivity.working => 'Đang làm phụ đề',
    SessionActivity.stuck =>
      'Hơn 20 giây chưa có gì mới: có thể mạng chậm hoặc đang chờ dịch. '
          'App tự nối lại sau 1 phút',
    SessionActivity.paused => 'Tạm nghỉ: phụ đề đã sẵn trước chỗ đang xem',
    SessionActivity.done => 'Xong',
    SessionActivity.failed => 'Đã dừng vì lỗi, xem Chi tiết phụ đề',
  };

  @override
  Widget build(BuildContext context) {
    final a = widget.session.activity;
    final s = widget.size;
    final Widget icon = switch (a) {
      SessionActivity.working => SizedBox.square(
        dimension: s - 2,
        child: const CircularProgressIndicator(
          strokeWidth: 2.5,
          color: Colors.greenAccent,
        ),
      ),
      SessionActivity.stuck => Icon(
        Icons.hourglass_bottom,
        size: s,
        color: Colors.orange,
      ),
      SessionActivity.paused => Icon(
        Icons.pause_circle,
        size: s,
        color: Colors.lightBlueAccent,
      ),
      SessionActivity.done => Icon(
        Icons.check_circle,
        size: s,
        color: Colors.green,
      ),
      SessionActivity.failed => Icon(
        Icons.error,
        size: s,
        color: Colors.redAccent,
      ),
    };
    return Tooltip(
      message: describe(a),
      triggerMode: TooltipTriggerMode.tap,
      child: Padding(padding: const EdgeInsets.all(2), child: icon),
    );
  }
}
