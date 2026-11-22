// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The two shared room routes of decision 0131.
extension SlimmApiModuleRooms on SlimmApi {
  /// Every module's state in [channelId]'s room; how a late joiner catches up.
  Future<List<ModuleRoom>> moduleRooms(String channelId) async {
    final json = await send('GET', '/channels/$channelId/module-rooms');
    final raw = json is Map ? json['rooms'] : null;
    if (raw is! List) return const [];
    return raw
        .map(ModuleRoom.tryParse)
        .whereType<ModuleRoom>()
        .toList(growable: false);
  }

  /// Sends [input] to [moduleId]'s room in [channelId]; the module decides what it means.
  Future<ModuleRoomInputResult> sendModuleRoomInput(
    String channelId,
    String moduleId,
    String input,
  ) async {
    final json = await send(
      'POST',
      '/channels/$channelId/module-rooms/$moduleId/inputs',
      body: {'input': input},
    );
    return ModuleRoomInputResult.fromJson(json! as Map<String, dynamic>);
  }
}
