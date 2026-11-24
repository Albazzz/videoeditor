import 'package:flutter/material.dart';

import '../services/subtitle_session.dart';

class SessionRetryButton extends StatelessWidget {
  const SessionRetryButton({super.key, required this.session});
  final SubtitleSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) => session.canRetry || session.retrying
        ? TextButton.icon(
            onPressed: session.retrying ? null : session.retry,
            icon: const Icon(Icons.refresh),
            label: Text(session.retrying ? 'Đang thử lại…' : 'Thử lại'),
          )
        : const SizedBox.shrink(),
  );
}
