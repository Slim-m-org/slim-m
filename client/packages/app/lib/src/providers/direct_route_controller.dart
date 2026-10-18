// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reads the server's own-network addresses once this account is signed in.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;

import 'providers.dart';

/// The shortcut is an optimisation, so a server that cannot answer just leaves
/// requests on the public route.
final directRouteProvider = FutureProvider<void>((ref) async {
  try {
    await ref.watch(apiProvider).refreshDirectRoute();
  } on api.ApiException catch (error, stack) {
    api.reportFailure(api.LogTag.ui, 'future provider', error, stack);
    return;
  }
});
