// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Presence: batch status lookup and the caller's own visibility, the
/// `presence` tag.
extension SlimmApiPresence on SlimmApi {
  /// Batch presence lookup, deployment-wide like the member list: any
  /// authenticated caller may ask about any user id. An id with nothing live
  /// to report (never existed, or deleted) is simply absent from the result.
  Future<List<PresenceStatus>> listPresence(List<String> userIds) async {
    final json = await send(
      'GET',
      '/presence',
      query: {'ids': userIds.join(',')},
    );
    return (json as List<dynamic>)
        .map((p) => PresenceStatus.fromJson(p as Map<String, dynamic>))
        .toList(growable: false);
  }

  /// Sets the caller's own visibility preference. Takes effect for every live
  /// viewer at once, not on their next reconnect.
  Future<PresenceVisibility> setPresenceVisibility(
    PresenceVisibility visibility,
  ) async {
    final json = await send(
      'PATCH',
      '/presence',
      body: {'visibility': visibility.wire},
    );
    return PresenceVisibility.parse(
      (json as Map<String, dynamic>)['visibility'] as String,
    );
  }

  /// Says what the caller is listening to or playing. Held in memory against
  /// their live socket or heartbeat and never stored.
  Future<void> setPresenceActivity(PresenceActivity activity) async {
    await send('PUT', '/presence/activity', body: activity.toJson());
  }

  /// Clears the caller's activity. Idempotent.
  Future<void> clearPresenceActivity() async {
    await send('DELETE', '/presence/activity');
  }

  /// Keeps the caller present for [ttlSeconds] (1 to 300) without a socket,
  /// reading as [status] (`online`, `away` or `dnd`) with [activity], until it
  /// is sent again, ended or lapses. For clients that only speak HTTP.
  Future<PresenceHeartbeat> heartbeatPresence({
    String? status,
    PresenceActivity? activity,
    int? ttlSeconds,
  }) async {
    final json = await send(
      'PUT',
      '/presence/heartbeat',
      body: {
        if (status != null) 'status': status,
        if (activity != null) 'activity': activity.toJson(),
        if (ttlSeconds != null) 'ttl_seconds': ttlSeconds,
      },
    );
    return PresenceHeartbeat.fromJson(json as Map<String, dynamic>);
  }

  /// Ends the caller's heartbeat now. Idempotent.
  Future<void> endPresenceHeartbeat() async {
    await send('DELETE', '/presence/heartbeat');
  }

  /// Who is shown on every open board the caller can view, in one read.
  /// Only boards with at least one viewer are listed.
  Future<List<CanvasBoardViewers>> canvasViewers() async {
    final json = await send('GET', '/presence/canvas-viewers');
    return ((json as Map<String, dynamic>)['channels'] as List<dynamic>)
        .map((c) => CanvasBoardViewers.fromJson(c as Map<String, dynamic>))
        .toList(growable: false);
  }
}
