import 'package:flutter/material.dart';

import '../models/cue.dart';
import '../services/subtitle_session.dart';
import 'common.dart';

/// Lists subtitle lines: time, Vietnamese text and the original speech.
class CueList extends StatelessWidget {
  const CueList({
    super.key,
    required this.cues,
    this.controller,
    this.shrinkWrap = false,
  });

  final List<Cue> cues;
  final ScrollController? controller;
  final bool shrinkWrap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (cues.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: Text('Chưa có dòng phụ đề nào')),
      );
    }
    return ListView.separated(
      controller: controller,
      shrinkWrap: shrinkWrap,
      itemCount: cues.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final c = cues[i];
        final showSource = c.source.isNotEmpty && c.source != c.text;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 52,
                child: Text(
                  formatTime(c.start),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.primary,
                  ),
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SelectableText(c.text),
                    if (showSource)
                      SelectableText(
                        c.source,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Bottom sheet for a running session: every stage of the pipeline and the
/// lines made so far. Shows why nothing appears when nothing does.
Future<void> showSessionDetails(BuildContext context, SubtitleSession session) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final theme = Theme.of(context);
          return CustomScrollView(
            controller: scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Chi tiết phụ đề',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: SelectableText(
                          session.details,
                          style: theme.textTheme.bodySmall?.copyWith(
                            height: 1.5,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Các dòng đã có (${session.cues.length})',
                        style: theme.textTheme.titleSmall,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: CueList(cues: List.of(session.cues), shrinkWrap: true),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          );
        },
      ),
    ),
  );
}
