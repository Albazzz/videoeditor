import 'package:flutter/material.dart';

import '../services/open_page.dart';
import '../widgets/bookmarks_sheet.dart';

/// The saved pages as a tab: a tap opens the page in the browser.
class SavedPagesScreen extends StatelessWidget {
  const SavedPagesScreen({super.key, this.visit = 0});

  final int visit;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Trang đã lưu')),
    body: SafeArea(
      child: BookmarksView(
        key: const PageStorageKey('saved-pages'),
        visit: visit,
        onOpen: requestOpenPage,
      ),
    ),
  );
}
