import 'package:flutter/material.dart';

/// The photo remains in place while selecting; only its overlay changes.
class SavedThumbnailCard extends StatelessWidget {
  const SavedThumbnailCard({
    super.key,
    required this.picture,
    required this.child,
    required this.onTap,
    required this.onLongPress,
    required this.picking,
    required this.selected,
    this.actions,
    this.sourceLabel,
  });
  final Widget picture, child;
  final Widget? actions;
  final VoidCallback? onTap, onLongPress;
  final bool picking, selected;
  final String? sourceLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Material(
        color: selected
            ? colors.secondaryContainer
            : colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(
            color: selected ? colors.primary : colors.outline,
            width: selected ? 2 : 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              children: [
                InkWell(
                  onTap: onTap,
                  onLongPress: onLongPress,
                  child: AspectRatio(aspectRatio: 16 / 9, child: picture),
                ),
                if (picking)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: Checkbox(
                        value: selected,
                        onChanged: (_) => onTap?.call(),
                      ),
                    ),
                  ),
                if (!picking && actions != null)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Material(
                      color: Colors.black54,
                      shape: const CircleBorder(),
                      child: actions,
                    ),
                  ),
              ],
            ),
            if (sourceLabel case final String label when label.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                child: Row(
                  children: [
                    Icon(
                      Icons.public,
                      size: 15,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(color: colors.onSurfaceVariant),
                      ),
                    ),
                  ],
                ),
              ),
            child,
          ],
        ),
      ),
    );
  }
}
