import 'package:flutter/material.dart';

/// Visible labels, so an icon alone never implies a complete translation.
class AssetMarks extends StatelessWidget {
  const AssetMarks({super.key, required this.translated, required this.audio});
  final bool translated, audio;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 4,
    children: [
      if (translated) const _Mark(Icons.translate, 'Có bản dịch'),
      if (audio) const _Mark(Icons.audio_file_outlined, 'Có âm thanh'),
    ],
  );
}

class _Mark extends StatelessWidget {
  const _Mark(this.icon, this.text);
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(icon, size: 14, color: Colors.tealAccent),
      const SizedBox(width: 4),
      Text(text, style: const TextStyle(fontSize: 12)),
    ],
  );
}
