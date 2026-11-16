import 'package:flutter/material.dart';

import '../services/app_settings.dart';

final _backgrounds = {0.0: 'Không nền', 0.4: 'Nhạt', 0.72: 'Vừa', 0.9: 'Đậm'};

/// Size, height, background and original line of the subtitles. Changes
/// apply at once; the sheet leaves the video visible above it.
Future<void> showSubtitleStyle(BuildContext context) => showModalBottomSheet(
  context: context,
  showDragHandle: true,
  barrierColor: Colors.transparent,
  builder: (_) => const _StyleSheet(),
);

class _StyleSheet extends StatelessWidget {
  const _StyleSheet();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: appSettings,
      builder: (context, _) {
        final bg = _backgrounds.keys.reduce(
          (a, b) =>
              (a - appSettings.subBg).abs() <= (b - appSettings.subBg).abs()
              ? a
              : b,
        );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Kiểu phụ đề', style: theme.textTheme.titleMedium),
                const SizedBox(height: 8),
                _label(
                  context,
                  'Cỡ chữ',
                  '${(appSettings.subScale * 100).round()}%',
                ),
                Slider(
                  value: appSettings.subScale,
                  min: 0.6,
                  max: 1.8,
                  divisions: 12,
                  onChanged: (v) => appSettings.setSubStyle(scale: v),
                ),
                _label(
                  context,
                  'Vị trí',
                  appSettings.subLift < 0.12
                      ? 'Sát dưới'
                      : appSettings.subLift < 0.35
                      ? 'Cao hơn'
                      : 'Giữa khung',
                ),
                Row(
                  children: [
                    const Text('Thấp'),
                    Expanded(
                      child: Slider(
                        value: appSettings.subLift,
                        min: 0.02,
                        max: 0.5,
                        divisions: 24,
                        onChanged: (v) => appSettings.setSubStyle(lift: v),
                      ),
                    ),
                    const Text('Cao'),
                  ],
                ),
                const SizedBox(height: 4),
                Text('Nền chữ', style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<double>(
                    showSelectedIcon: false,
                    segments: [
                      for (final e in _backgrounds.entries)
                        ButtonSegment(value: e.key, label: Text(e.value)),
                    ],
                    selected: {bg},
                    onSelectionChanged: (s) =>
                        appSettings.setSubStyle(bg: s.first),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hiện cả câu gốc'),
                  value: appSettings.showSource,
                  onChanged: appSettings.setShowSource,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () {
                      appSettings.setSubStyle(
                        scale: 1,
                        lift: kDefaultSubLift,
                        bg: 0.72,
                      );
                    },
                    child: const Text('Về mặc định'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _label(BuildContext context, String name, String value) => Row(
    children: [
      Text(name, style: Theme.of(context).textTheme.bodyMedium),
      const Spacer(),
      Text(value, style: Theme.of(context).textTheme.labelMedium),
    ],
  );
}
