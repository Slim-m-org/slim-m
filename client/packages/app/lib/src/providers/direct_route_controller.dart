// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads the server's own-network addresses once this account is signed in.
library;

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'app_lifecycle.dart';
import 'providers.dart';

/// The shortcut is an optimisation, so a server that cannot answer just leaves
/// requests on the public route.
final directRouteProvider = FutureProvider<void>((ref) async {
  final route = ref.watch(apiProvider);
  // A phone that resumes has often changed network while it slept.
  ref.listen(appLifecycleProvider, (previous, state) {
    if (state == AppLifecycleState.resumed) route.routeMayHaveChanged();
  });
  try {
    await route.refreshDirectRoute();
  } on api.ApiException catch (error, stack) {
    api.reportFailure(
      api.LogTag.ui,
      'refresh the direct route to the server',
      error,
      stack,
    );
    return;
  }
});
