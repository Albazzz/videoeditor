import 'package:flutter/material.dart';

/// A folder boundary shared by saved pages and the subtitle library.
class FolderGroupHeader extends StatelessWidget {
  const FolderGroupHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.expanded,
    this.onTap,
    this.actions,
  });

  final String title;
  final String subtitle;
  final bool expanded;
  final VoidCallback? onTap;
  final Widget? actions;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Material(
        color: colors.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: colors.outlineVariant),
          borderRadius: BorderRadius.vertical(
            top: const Radius.circular(12),
            bottom: Radius.circular(expanded ? 0 : 12),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: ListTile(
          leading: Icon(
            onTap == null
                ? Icons.folder_off_outlined
                : expanded
                ? Icons.folder_open_outlined
                : Icons.folder_outlined,
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: Text(subtitle),
          onTap: onTap,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (onTap != null)
                Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ?actions,
            ],
          ),
        ),
      ),
    );
  }
}

/// Keeps each lazily built child visibly inside its folder's boundary.
class FolderGroupEntry extends StatelessWidget {
  const FolderGroupEntry({super.key, required this.child, required this.last});

  final Widget child;
  final bool last;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Material(
        color: colors.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          side: BorderSide(color: colors.outlineVariant),
          borderRadius: BorderRadius.vertical(
            bottom: Radius.circular(last ? 12 : 0),
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsetsDirectional.only(start: 16),
          child: child,
        ),
      ),
    );
  }
}
