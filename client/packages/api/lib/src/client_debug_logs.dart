// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Debug logs sent to the admins: the `/debug-logs` routes.
extension SlimmApiDebugLogs on SlimmApi {
  /// Sends [log] to the admins. Any signed-in member may.
  Future<SubmittedDebugLog> submitDebugLog({
    required String log,
    required String appVersion,
    required String platform,
    String note = '',
  }) async {
    final json = await send(
      'POST',
      '/debug-logs',
      body: {
        'log': log,
        'note': note,
        'app_version': appVersion,
        'platform': platform,
      },
    );
    return SubmittedDebugLog.fromJson(json as Map<String, dynamic>);
  }

  /// One page of submitted logs, newest first. Requires MANAGE_SERVER.
  ///
  /// [before] is the [DebugLogEntry.id] of the oldest entry already held.
  Future<List<DebugLogEntry>> listDebugLogs({int? before, int? limit}) async {
    final query = <String, String>{
      if (before != null) 'before': '$before',
      if (limit != null) 'limit': '$limit',
    };
    final json = await send(
      'GET',
      '/debug-logs',
      query: query.isEmpty ? null : query,
    );
    return [
      for (final e in json as List<dynamic>)
        DebugLogEntry.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// One submitted log with its text. Requires MANAGE_SERVER.
  Future<DebugLogDownload> getDebugLog(int id) async {
    final json = await send('GET', '/debug-logs/$id');
    return DebugLogDownload.fromJson(json as Map<String, dynamic>);
  }

  /// Deletes one submitted log. Requires MANAGE_SERVER.
  Future<void> deleteDebugLog(int id) =>
      send('DELETE', '/debug-logs/$id', expectNoContent: true);
}
