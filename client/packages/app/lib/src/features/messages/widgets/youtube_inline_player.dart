// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline, click-to-play YouTube embed - web only.
///
/// Flutter carries no iframe host off the web engine, and this app does not
/// add a webview dependency to fake one; see `link_preview_card.dart` for
/// why every other platform opens the video in the system browser instead.
/// `youtube_inline_player_web.dart` is the real embed; the non-web branch is
/// an unreachable stub so the conditional import still resolves everywhere.
library;

export 'youtube_inline_player_stub.dart'
    if (dart.library.js_interop) 'youtube_inline_player_web.dart';
