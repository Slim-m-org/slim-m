// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// The two shared room routes of decision 0131.
extension SlimmApiModuleRooms on SlimmApi {
  /// Every module's state in [channelId]'s room, how a late joiner catches
  /// up, and the call scenes on offer there.
  Future<ModuleRooms> moduleRooms(String channelId) async =>
      ModuleRooms.fromJson(
        await send('GET', '/channels/$channelId/module-rooms'),
      );

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
