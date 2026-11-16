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
