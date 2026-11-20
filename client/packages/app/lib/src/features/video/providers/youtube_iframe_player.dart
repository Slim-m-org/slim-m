// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The web build's [EmbeddedVideoPlayer]: YouTube's own embed in an iframe,
/// driven over the embed's postMessage channel. Other platforms get an
/// unreachable stub so the conditional import resolves everywhere.
library;

export 'youtube_iframe_player_stub.dart'
    if (dart.library.js_interop) 'youtube_iframe_player_web.dart';
