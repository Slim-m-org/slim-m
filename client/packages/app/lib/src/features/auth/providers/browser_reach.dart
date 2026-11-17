// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a Space answers when the browser's cross-origin rules are not in
/// the way, to tell a blocked request apart from an unreachable address.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'browser_reach_stub.dart'
    if (dart.library.js_interop) 'browser_reach_web.dart';

/// True when [server]'s `/healthz` answers at all, false when nothing does,
/// and null where no browser stands between the app and the server.
typedef BrowserReachProbe = Future<bool?> Function(Uri server);

final browserReachProbeProvider = Provider<BrowserReachProbe>(
  (ref) => answersOutsideBrowserRules,
);
