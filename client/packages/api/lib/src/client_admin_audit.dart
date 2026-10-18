// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'client.dart';

/// The admin audit log: the `space` tag's `GET /space/audit-log`.
extension SlimmApiAdminAudit on SlimmApi {
  /// One page of admin changes, newest first. Requires MANAGE_SERVER.
  ///
  /// [before] is the [AdminChange.id] of the oldest change already held.
  Future<List<AdminChange>> listAdminChanges({int? before, int? limit}) async {
    final query = <String, String>{
      if (before != null) 'before': '$before',
      if (limit != null) 'limit': '$limit',
    };
    final json = await _send(
      'GET',
      '/space/audit-log',
      query: query.isEmpty ? null : query,
    );
    return [
      for (final e in json as List<dynamic>)
        AdminChange.fromJson(e as Map<String, dynamic>),
    ];
  }
}
