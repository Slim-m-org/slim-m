// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';
import 'exceptions.dart';

/// Module tiles on a voice canvas (add-on API 6): discovering them, reading a tile's frame, pressing it.
extension SlimmApiCanvasTiles on SlimmApi {
  /// Every tile this caller may place, possibly empty; a server without tiles answers with none.
  Future<List<CanvasTileOffer>> listCanvasTiles() async {
    final Object? json;
    try {
      json = await send('GET', '/modules/canvas-tiles');
    } on NotFoundException {
      return const [];
    }
    if (json is! List) return const [];
    return json
        .whereType<Map<String, dynamic>>()
        .map(CanvasTileOffer.fromJson)
        .toList(growable: false);
  }

  /// The tile's frame, or null before its first launch. A tile whose module cannot run throws [ConflictException].
  Future<CanvasTileScene?> canvasTileScene({
    required String channelId,
    required String objectId,
  }) async {
    try {
      final json = await send(
        'GET',
        '/channels/$channelId/canvas/objects/$objectId/scene',
      );
      return CanvasTileScene.fromJson(json as Map<String, dynamic>);
    } on NotFoundException catch (e) {
      if (e.unexplained) rethrow;
      return null;
    }
  }

  /// Presses the tile with an action frame, or launches it with an empty [input].
  Future<RunModuleCommandResult> pressCanvasTile({
    required String channelId,
    required String objectId,
    required String input,
  }) async {
    final json = await send(
      'POST',
      '/channels/$channelId/canvas/objects/$objectId/scene',
      body: {'input': input},
    );
    return RunModuleCommandResult.fromJson(json as Map<String, dynamic>);
  }
}
