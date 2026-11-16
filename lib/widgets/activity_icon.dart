import 'dart:async';

import 'package:flutter/material.dart';

import '../services/subtitle_session.dart';
import 'session_progress.dart';

/// Shows at a glance whether subtitles are being made: a turning circle
/// while work moves on, an hourglass when nothing has happened for 20
/// seconds, pause, done or error. Tapping opens the step-by-step view.
class ActivityIcon extends StatefulWidget {
  const ActivityIcon({
    super.key,
    required this.session,
    this.size = 18,
    this.title = '',
    this.tappable = true,
  });
  final SubtitleSession session;
  final double size;
  final String title;
  final bool tappable;

  @override
  State<ActivityIcon> createState() => _ActivityIconState();

  static String describe(SessionActivity a) => switch (a) {
    SessionActivity.working => 'Đang làm phụ đề',
    SessionActivity.stuck =>
      'Hơn 20 giây chưa có gì mới: có thể mạng chậm hoặc đang chờ dịch. '
          'App tự nối lại sau 1 phút',
    SessionActivity.paused => 'Tạm nghỉ: phụ đề đã sẵn trước chỗ đang xem',
    SessionActivity.done => 'Xong',
    SessionActivity.failed => 'Đã dừng vì lỗi, xem Chi tiết phụ đề',
  };
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
    final child = Padding(padding: const EdgeInsets.all(4), child: icon);
    if (!widget.tappable) return child;
    return InkResponse(
      radius: s,
      onTap: () =>
          showSessionProgress(context, widget.session, title: widget.title),
      child: Tooltip(message: ActivityIcon.describe(a), child: child),
    );
  }
}
