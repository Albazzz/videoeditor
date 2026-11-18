import 'package:flutter/foundation.dart';

/// A tab's identity survives navigation and changes to its position in the list.
class BrowserTab {
  BrowserTab(this.id, this.initialUrl, {this.windowId}) : url = initialUrl;

  final int id;
  final String initialUrl;
  final int? windowId;
  String url;
  String title = '';
  bool canGoBack = false;

  String get label => title.isNotEmpty ? title : Uri.tryParse(url)?.host ?? url;
}

/// Each tab owns a WebView and therefore its own native back/forward stack.
class BrowserTabs extends ChangeNotifier {
  BrowserTabs({required this.homeUrl}) {
    add();
  }

  final String homeUrl;
  final _tabs = <BrowserTab>[];
  int _nextId = 0;
  int _selectedId = 0;

  List<BrowserTab> get tabs => List.unmodifiable(_tabs);
  BrowserTab get selected => _tabs.firstWhere((t) => t.id == _selectedId);
  int get selectedIndex => _tabs.indexOf(selected);

  BrowserTab add({String? url, int? windowId, bool select = true}) {
    final tab = BrowserTab(_nextId++, url ?? homeUrl, windowId: windowId);
    _tabs.add(tab);
    if (select || _tabs.length == 1) _selectedId = tab.id;
    notifyListeners();
    return tab;
  }

  void select(int id) {
    if (id == _selectedId || !_tabs.any((t) => t.id == id)) return;
    _selectedId = id;
    notifyListeners();
  }

  void close(int id) {
    final index = _tabs.indexWhere((t) => t.id == id);
    if (index < 0) return;
    _tabs.removeAt(index);
    if (_tabs.isEmpty) {
      add();
      return;
    }
    if (_selectedId == id) {
      _selectedId = _tabs[index < _tabs.length ? index : index - 1].id;
    }
    notifyListeners();
  }

  void update(int id, {String? url, String? title, bool? canGoBack}) {
    final tab = _tabs.where((t) => t.id == id).firstOrNull;
    if (tab == null) return;
    if ((url == null || tab.url == url) &&
        (title == null || tab.title == title) &&
        (canGoBack == null || tab.canGoBack == canGoBack)) {
      return;
    }
    if (url != null) tab.url = url;
    if (title != null) tab.title = title;
    if (canGoBack != null) tab.canGoBack = canGoBack;
    notifyListeners();
  }
}
