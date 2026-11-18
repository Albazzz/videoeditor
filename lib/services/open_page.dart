import 'package:flutter/foundation.dart';

/// A page another screen wants opened in the browser tab (the subtitle
/// store's "open page" button). The home screen switches to the browser
/// and the browser loads it.
final openPageRequest = ValueNotifier<String?>(null);

void requestOpenPage(String url) {
  // Re-set even when unchanged, so the same page can be opened again.
  openPageRequest.value = null;
  openPageRequest.value = url;
}

final _resume = <String>{};

String _resumeKey(String page) =>
    Uri.tryParse(page)?.removeFragment().toString() ?? page;

/// "Làm tiếp" from the subtitle store: open the page and carry on making
/// subtitles once its video plays (the browser asks [takeResume]).
void requestResume(String page) {
  _resume.add(_resumeKey(page));
  requestOpenPage(page);
}

/// True once for a page the user asked to carry on.
bool takeResume(String page) => _resume.remove(_resumeKey(page));
