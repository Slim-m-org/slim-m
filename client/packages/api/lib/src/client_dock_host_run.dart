// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Host-run connectors (decision 0134): whether this server can run them, and
/// one connector's state and recent output. Every route requires MANAGE_SERVER.
extension SlimmApiDockHostRun on SlimmApi {
  /// Whether the operator set up the connector supervisor, and whether it answers.
  Future<ConnectorRuntimeStatus> getConnectorRuntime() async {
    final json = await send('GET', '/space/dock/connector-runtime');
    return ConnectorRuntimeStatus.fromJson(json as Map<String, dynamic>);
  }

  /// A host-run connector's state; 404 for a connector the host does not run.
  Future<ConnectorHostRun> getConnectorHostRun(String moduleId) async {
    final json = await send('GET', '/space/dock/modules/$moduleId/host-run');
    return ConnectorHostRun.fromJson(json as Map<String, dynamic>);
  }

  /// Its newest output lines, read from the runtime on demand.
  Future<List<HostRunLogLine>> getConnectorHostRunLogs(
    String moduleId, {
    int tail = 200,
  }) async {
    final json = await send(
      'GET',
      '/space/dock/modules/$moduleId/host-run/logs',
      query: {'tail': '$tail'},
    );
    return [
      for (final line in (json as Map<String, dynamic>)['lines'] as List)
        HostRunLogLine.fromJson(line as Map<String, dynamic>),
    ];
  }
}
