// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The browser half of `browser_reach.dart`.
///
/// A `no-cors` fetch resolves with an unreadable reply whenever the server
/// answers, and rejects only when nothing does, so it says whether the
/// address is up without needing the server to allow this origin.
library;

import 'dart:js_interop';

import 'package:web/web.dart' as web;

Future<bool?> answersOutsideBrowserRules(Uri server) async {
  final healthz = server.replace(path: '/healthz').toString();
  try {
    await web.window
        .fetch(
          healthz.toJS,
          web.RequestInit(mode: 'no-cors', cache: 'no-store'),
        )
        .toDart
        .timeout(const Duration(seconds: 8));
    return true;
  } on Object {
    return false;
  }
}
