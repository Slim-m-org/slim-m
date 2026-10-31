// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Direct-message conversations, the `dms` tag.
extension SlimmApiDms on SlimmApi {
  /// Lists the caller's DM conversations, most recently active first. Each
  /// channel id works with the ordinary message, search, and sync routes
  /// exactly like any other channel.
  Future<List<DmConversation>> listDirectMessages() async {
    final json = await send('GET', '/dms');
    return (json as List<dynamic>)
        .map((d) => DmConversation.fromJson(d as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Opens (or returns) the DM channel with [userId] - or, passing the
  /// caller's own id, their personal space. Idempotent and race-safe:
  /// opening the same pair twice, even concurrently, converges on one
  /// channel. Refused if either party has blocked the other.
  Future<DmConversation> openDirectMessage(String userId) async {
    final json = await send('POST', '/dms/$userId');
    return DmConversation.fromJson(json as Map<String, dynamic>);
  }

  /// Closes the DM with [userId] out of the caller's own sidebar - a
  /// per-viewer hide, never a delete: no message is touched, and the other
  /// participant's own list is unaffected. Reappears on its own once they
  /// send something new, or the moment the caller opens or messages them
  /// again. Idempotent, and a no-op if the pair has no DM channel yet.
  Future<void> hideDirectMessage(String userId) =>
      send('DELETE', '/dms/$userId', expectNoContent: true);

  /// Starts a group DM with [userIds], 2 to 7 other people (3 to 8 with the
  /// caller). [id] is a client-chosen UUIDv7 that makes a retry find the
  /// group it already made. Refused with 403 if any two of the people have a
  /// block between them.
  Future<DmConversation> createGroupDirectMessage(
    List<String> userIds, {
    required String id,
    String? name,
  }) async {
    final json = await send('POST', '/dms/groups', body: {
      'id': id,
      'user_ids': userIds,
      if (name != null) 'name': name,
    });
    return DmConversation.fromJson(json as Map<String, dynamic>);
  }

  /// Adds [userId] to a group DM the caller is in. Refused with 403 if they
  /// have a block with anyone in it, and 409 if it is full.
  Future<DmConversation> addGroupDirectMessageMember(
    String channelId,
    String userId,
  ) async {
    final json = await send(
      'POST',
      '/dms/groups/$channelId/members',
      body: {'user_id': userId},
    );
    return DmConversation.fromJson(json as Map<String, dynamic>);
  }

  /// Sets a group DM's custom name; null or blank goes back to the default.
  Future<DmConversation> renameGroupDirectMessage(
    String channelId,
    String? name,
  ) async {
    final json = await send(
      'PATCH',
      '/dms/groups/$channelId',
      body: {'name': name},
    );
    return DmConversation.fromJson(json as Map<String, dynamic>);
  }

  /// Leaves a group DM. The rest keep it; the last one out deletes it.
  Future<void> leaveGroupDirectMessage(String channelId) =>
      send('POST', '/dms/groups/$channelId/leave', expectNoContent: true);
}
