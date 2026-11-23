// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Host-run connectors (decision 0134): whether this server can run them, and
/// one connector's state and recent output, for the Dock's admin pages.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_api/api.dart' show SlimmApiDockHostRun;

import '../../../providers/providers.dart';

final connectorRuntimeProvider =
    FutureProvider.autoDispose<api.ConnectorRuntimeStatus>(
      (ref) => ref.watch(apiProvider).getConnectorRuntime(),
    );

final connectorHostRunProvider = FutureProvider.autoDispose
    .family<api.ConnectorHostRun, String>(
      (ref, moduleId) => ref.watch(apiProvider).getConnectorHostRun(moduleId),
    );

/// The newest lines, fewest first, as the panel shows them.
final connectorHostRunLogsProvider = FutureProvider.autoDispose
    .family<List<api.HostRunLogLine>, String>(
      (ref, moduleId) =>
          ref.watch(apiProvider).getConnectorHostRunLogs(moduleId, tail: 50),
    );
