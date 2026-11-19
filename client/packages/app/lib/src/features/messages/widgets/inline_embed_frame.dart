// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An inline, click-to-play provider embed (a YouTube or Spotify player) -
/// web only.
///
/// Other platforms play a YouTube video through `features/video` instead;
/// see `link_preview_card.dart`. `inline_embed_frame_web.dart` is the real
/// embed; the non-web branch is an unreachable stub so the conditional
/// import still resolves everywhere.
library;

export 'inline_embed_frame_stub.dart'
    if (dart.library.js_interop) 'inline_embed_frame_web.dart';
