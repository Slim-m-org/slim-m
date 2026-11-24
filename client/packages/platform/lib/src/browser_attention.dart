// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a browser tab can do to be noticed while it is in the background: an unread count in the tab title and favicon, and a page notification.
///
/// Native platforms have their own surfaces for this, so they get a no-op.
library;

import 'browser_attention_io.dart'
    if (dart.library.js_interop) 'browser_attention_web.dart' as impl;

/// The tab title for [base] with [unread] conversations waiting.
String tabTitleFor(String base, int unread) =>
    unread > 0 ? '($unread) $base' : base;

abstract interface class BrowserAttention {
  factory BrowserAttention() => impl.createBrowserAttention();

  /// Shows [unread] in the tab title and as a dot on the favicon; zero restores both.
  void setUnread(int unread);

  /// Raises a page notification when the tab is hidden and the person already allowed them; [onClick] runs when it is clicked.
  void notify(
    String title,
    String body, {
    required String tag,
    void Function()? onClick,
  });
}
