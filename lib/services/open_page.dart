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

final _restart = <String>{};

/// "Làm lại từ đầu": like [requestResume], after the old subtitles were
/// deleted; the page also stops showing the old lines it may still have.
void requestRestart(String page) {
  _restart.add(_resumeKey(page));
  requestResume(page);
}

/// True once for a page whose subtitles start over.
bool takeRestart(String page) => _restart.remove(_resumeKey(page));

/// Several pages at once (picked in a list): the first opens in front,
/// the others in background tabs.
final openPagesRequest = ValueNotifier<List<String>?>(null);

void requestOpenPages(List<String> urls) {
  if (urls.isEmpty) return;
  openPagesRequest.value = null;
  openPagesRequest.value = List.unmodifiable(urls);
}

/// "Làm tiếp" for several films: each page opens in its own tab and
/// carries on once its film plays there.
void requestResumeAll(List<String> pages) {
  for (final page in pages) {
    _resume.add(_resumeKey(page));
  }
  requestOpenPages(pages);
}

/// Opens the subtitle library without exposing any page in system notifications.
final openSubtitleLibrary = ValueNotifier<int>(0);
