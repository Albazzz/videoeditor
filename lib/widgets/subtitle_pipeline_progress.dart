import 'package:flutter/material.dart';

import '../services/subtitle_session.dart';
import '../services/subtitle_store.dart';
import '../services/audio_availability.dart';

/// Downloaded audio, recognised time and translated lines are separate stages.
class SubtitlePipelineProgress extends StatelessWidget {
  const SubtitlePipelineProgress({super.key, required this.session});
  final SubtitleSession session;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: session,
    builder: (context, _) {
      final audio = session.audioAvailability;
      final heard = coveredSeconds(session.covered);
      final fraction = session.duration > 0
          ? (heard / session.duration).clamp(0.0, 1.0)
          : null;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(audio.label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: audio.fraction ?? (session.downloadingAudio ? null : 0),
            semanticsLabel: 'Âm thanh đã lưu',
          ),
          const SizedBox(height: 6),
          Text(
            'Đã nhận dạng: ${fraction == null ? AudioAvailability.clock(heard) : '${(fraction * 100).floor()}% · ${AudioAvailability.clock(heard)} / ${AudioAvailability.clock(session.duration)}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: fraction ?? 0,
            semanticsLabel: 'Đã nhận dạng',
          ),
          const SizedBox(height: 6),
          Text(
            'Đã dịch: ${session.translatedCount} / ${session.cues.length} câu đã nhận dạng'
            '${session.waitingTranslation > 0 ? ' · chờ ${session.waitingTranslation}' : ''}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (session.needsAudioSource)
            Text(
              'Âm thanh chưa đủ, thiếu từ ${AudioAvailability.clock(audio.firstMissing)}. '
              'Cần mở lại nguồn để lấy phần thiếu; phần đã làm vẫn được giữ.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          if (session.activity == SessionActivity.stuck)
            Text(
              'Chưa có tiến triển trong ${DateTime.now().difference(session.lastActivity).inSeconds} giây. Mở tiến trình để kiểm tra hoặc thử lại.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.error,
              ),
            ),
        ],
      );
    },
  );
}
