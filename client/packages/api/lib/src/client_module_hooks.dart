// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The hooks installed modules have placed in front of actions. Both routes
/// require MANAGE_SERVER.
extension SlimmApiModuleHooks on SlimmApi {
  /// Every hook in the order it runs.
  Future<List<ModuleHook>> moduleHooks() async {
    final json = await send('GET', '/space/dock/hooks');
    return [
      for (final entry in json as List<dynamic>)
        ModuleHook.fromJson(entry as Map<String, dynamic>),
    ];
  }

  /// Changes one hook's priority or whether a failure refuses the action.
  Future<void> updateModuleHook(
    String moduleId, {
    required String kind,
    required String hook,
    String phase = '',
    int? priority,
    bool? failClosed,
  }) async {
    await send(
      'PUT',
      '/space/dock/modules/$moduleId/hooks',
      body: {
        'kind': kind,
        'hook': hook,
        'phase': phase,
        if (priority != null) 'priority': priority,
        if (failClosed != null) 'fail_closed': failClosed,
      },
    );
  }
}
