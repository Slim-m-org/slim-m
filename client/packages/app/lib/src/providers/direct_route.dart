// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether the app reaches the server over its own network right now.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';

final directRouteProvider = StreamProvider<bool>((ref) async* {
  final api = ref.watch(apiProvider);
  yield api.usesDirectRoute;
  yield* api.directRouteChanges;
});
