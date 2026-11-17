import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

/// Return the native history item, rather than loading its URL again: this
/// keeps the forward stack and distinguishes repeat visits to the same URL.
Future<WebHistoryItem?> showBrowserHistory(
  BuildContext context,
  WebHistory history,
) => showModalBottomSheet<WebHistoryItem>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) {
    final items = history.list ?? <WebHistoryItem>[];
    final current = history.currentIndex;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.72,
        child: Column(
          children: [
            Text('Lịch sử tab', style: Theme.of(context).textTheme.titleLarge),
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Chọn trang để quay lại hoặc đi tới'),
            ),
            if (items.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('Tab này chưa có lịch sử'),
              ),
            Expanded(
              child: ListView.builder(
                itemCount: items.length,
                itemBuilder: (context, row) {
                  final index = items.length - row - 1;
                  final item = items[index];
                  final isCurrent = index == current;
                  final forward = current != null && index > current;
                  final url = item.url?.toString() ?? '';
                  return ListTile(
                    selected: isCurrent,
                    leading: Icon(
                      isCurrent
                          ? Icons.radio_button_checked
                          : forward
                          ? Icons.arrow_forward
                          : Icons.arrow_back,
                    ),
                    title: Text(
                      item.title?.isNotEmpty == true ? item.title! : url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: isCurrent ? const Text('Hiện tại') : null,
                    onTap: () => Navigator.pop(context, item),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  },
);
