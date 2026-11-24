import 'package:flutter/material.dart';

import '../services/background_subtitles.dart';

class BackgroundSubtitlesBar extends StatelessWidget {
  const BackgroundSubtitlesBar({super.key, required this.onOpen});
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder(
    valueListenable: BackgroundSubtitles.instance.state,
    builder: (context, state, _) {
      if (state.total == 0) return const SizedBox.shrink();
      final done = state.completed == state.total;
      return Material(
        color: Theme.of(context).colorScheme.surfaceContainerHigh,
        child: InkWell(
          onTap: onOpen,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: state.progress / 10000,
                minHeight: 2,
              ),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Icon(
                      done
                          ? Icons.check_circle_outline
                          : Icons.subtitles_outlined,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(child: Text(state.label)),
                    if (state.canDismiss)
                      IconButton(
                        tooltip: 'Ẩn tiến trình đã xong',
                        onPressed: BackgroundSubtitles.instance.dismiss,
                        icon: const Icon(Icons.close, size: 18),
                      )
                    else
                      IconButton(
                        tooltip: 'Xem tiến trình phụ đề',
                        onPressed: onOpen,
                        icon: const Icon(Icons.chevron_right, size: 18),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
