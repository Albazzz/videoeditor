import 'dart:async';

import 'package:flutter/material.dart';

import '../services/subtitle_session.dart';
import '../services/subtitle_store.dart';
import 'activity_icon.dart';
import 'common.dart';
import 'subtitle_details.dart';

/// Every step from pressing CC to translated lines, live.
Future<void> showSessionProgress(
  BuildContext context,
  SubtitleSession session, {
  String title = '',
}) => showModalBottomSheet(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _ProgressSheet(session: session, title: title),
);

class _ProgressSheet extends StatefulWidget {
  const _ProgressSheet({required this.session, required this.title});
  final SubtitleSession session;
  final String title;

  @override
  State<_ProgressSheet> createState() => _ProgressSheetState();
}

class _ProgressSheetState extends State<_ProgressSheet> {
  late final Timer _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
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
    final theme = Theme.of(context);
    final s = widget.session;
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        final whole = coversWholeVideo(
          s.covered,
          s.duration,
          reachedEnd: s.reachedEnd,
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      ActivityIcon(session: s, size: 22, tappable: false),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          widget.title.isEmpty
                              ? 'Tiến trình phụ đề'
                              : widget.title,
                          style: theme.textTheme.titleMedium,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Đang làm gì ngay lúc này',
                    style: theme.textTheme.labelLarge,
                  ),
                  Text(s.stage),
                  const SizedBox(height: 10),
                  if (s.duration > 0) ...[
                    CoverageBar(
                      covered: s.covered,
                      duration: s.duration,
                      done: whole,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitleProgressLabel(
                        covered: s.covered,
                        duration: s.duration,
                        reachedEnd: whole,
                      ),
                      style: theme.textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                  ],
                  for (final (i, step) in s.steps.indexed)
                    _StepRow(number: i + 1, step: step),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Spacer(),
                      TextButton(
                        onPressed: () => showSessionDetails(context, s),
                        child: const Text('Chi tiết'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _StepRow extends StatelessWidget {
  const _StepRow({required this.number, required this.step});
  final int number;
  final SessionStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget mark = switch (step.state) {
      StageState.done => const Icon(
        Icons.check_circle,
        color: Colors.green,
        size: 20,
      ),
      StageState.active => const SizedBox.square(
        dimension: 18,
        child: CircularProgressIndicator(strokeWidth: 2.5),
      ),
      StageState.failed => const Icon(
        Icons.error,
        color: Colors.redAccent,
        size: 20,
      ),
      StageState.skipped => Icon(
        Icons.remove_circle_outline,
        color: theme.disabledColor,
        size: 20,
      ),
      StageState.waiting => Icon(
        Icons.radio_button_unchecked,
        color: theme.disabledColor,
        size: 20,
      ),
    };
    final dim =
        step.state == StageState.waiting || step.state == StageState.skipped;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 24, child: Center(child: mark)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$number. ${step.title}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: dim ? theme.disabledColor : null,
                    fontWeight: step.state == StageState.active
                        ? FontWeight.w600
                        : null,
                  ),
                ),
                if (step.detail.isNotEmpty)
                  Text(
                    step.detail,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: step.state == StageState.failed
                          ? Colors.redAccent
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
