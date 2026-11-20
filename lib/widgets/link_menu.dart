import 'dart:convert';

import 'package:flutter/material.dart';

/// What was under the finger on a long press: a link, a picture, or both.
class PressedLink {
  const PressedLink({this.href = '', this.text = '', this.image = ''});

  /// From the page script's answer (JSON), falling back to what the web
  /// view itself found ([fallback], a link or picture address).
  factory PressedLink.parse(
    Object? raw, {
    String? fallback,
    bool isImage = false,
  }) {
    var href = '', text = '', image = '';
    try {
      final data = raw is String && raw.isNotEmpty ? jsonDecode(raw) : raw;
      if (data is Map) {
        href = '${data['href'] ?? ''}';
        text = '${data['text'] ?? ''}'.replaceAll(RegExp(r'\s+'), ' ').trim();
        image = '${data['img'] ?? ''}';
      }
    } catch (_) {}
    if (href.isEmpty && image.isEmpty && fallback != null) {
      if (isImage) {
        image = fallback;
      } else {
        href = fallback;
      }
    }
    return PressedLink(href: _web(href), text: text, image: _web(image));
  }

  static String _web(String url) {
    final u = Uri.tryParse(url);
    return u != null && (u.isScheme('http') || u.isScheme('https')) ? url : '';
  }

  final String href, text, image;
  bool get isEmpty => href.isEmpty && image.isEmpty;
}

enum LinkAction {
  newTab,
  backgroundTab,
  here,
  copyLink,
  copyText,
  save,
  openImage,
  copyImage,
}

/// Chrome-like menu for a long-pressed link or picture.
Future<LinkAction?> showLinkMenu(BuildContext context, PressedLink link) {
  final theme = Theme.of(context);
  Widget item(LinkAction a, IconData icon, String label) => ListTile(
    leading: Icon(icon),
    title: Text(label),
    onTap: () => Navigator.pop(context, a),
  );
  return showModalBottomSheet<LinkAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (link.text.isNotEmpty)
                    Text(
                      link.text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  Text(
                    link.href.isNotEmpty ? link.href : link.image,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            if (link.href.isNotEmpty) ...[
              item(LinkAction.newTab, Icons.open_in_new, 'Mở trong tab mới'),
              item(
                LinkAction.backgroundTab,
                Icons.tab_unselected,
                'Mở trong tab nền',
              ),
              item(LinkAction.here, Icons.open_in_browser, 'Mở ở tab này'),
              item(
                LinkAction.copyLink,
                Icons.link,
                'Sao chép địa chỉ liên kết',
              ),
              if (link.text.isNotEmpty)
                item(LinkAction.copyText, Icons.short_text, 'Sao chép chữ'),
              item(LinkAction.save, Icons.star_border, 'Lưu trang liên kết'),
            ],
            if (link.image.isNotEmpty) ...[
              if (link.href.isNotEmpty) const Divider(height: 1),
              item(
                LinkAction.openImage,
                Icons.image_outlined,
                'Mở ảnh trong tab mới',
              ),
              item(LinkAction.copyImage, Icons.copy, 'Sao chép địa chỉ ảnh'),
            ],
          ],
        ),
      ),
    ),
  );
}
