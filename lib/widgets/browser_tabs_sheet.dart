import 'package:flutter/material.dart';

import '../services/browser_tabs.dart';

Future<void> showBrowserTabs(
  BuildContext context,
  BrowserTabs tabs, {
  required VoidCallback onNewTab,
  required ValueChanged<int> onClose,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    child: SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: ListenableBuilder(
        listenable: tabs,
        builder: (context, _) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${tabs.tabs.length} tab đang mở',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  if (tabs.tabs.length > 1)
                    IconButton(
                      tooltip: 'Đóng các tab khác',
                      icon: const Icon(Icons.layers_clear_outlined),
                      onPressed: () {
                        final keep = tabs.selected.id;
                        for (final t in List.of(tabs.tabs)) {
                          if (t.id != keep) onClose(t.id);
                        }
                      },
                    ),
                  TextButton.icon(
                    icon: const Icon(Icons.add),
                    label: const Text('Tab mới'),
                    onPressed: () {
                      Navigator.pop(context);
                      onNewTab();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                itemCount: tabs.tabs.length,
                itemBuilder: (context, index) {
                  final tab = tabs.tabs[index];
                  final selected = tab.id == tabs.selected.id;
                  return ListTile(
                    key: ValueKey('tab-${tab.id}'),
                    selected: selected,
                    selectedTileColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    leading: Icon(selected ? Icons.tab : Icons.tab_outlined),
                    title: Text(
                      tab.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: Text(
                      tab.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: IconButton(
                      tooltip: 'Đóng tab ${tab.label}',
                      icon: const Icon(Icons.close),
                      onPressed: () => onClose(tab.id),
                    ),
                    onTap: () {
                      Navigator.pop(context);
                      tabs.select(tab.id);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);
