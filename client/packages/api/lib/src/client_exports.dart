// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Exporting your own data, and a whole space for an administrator
/// (`docs/data-export-format.md`). Starting one is a background job: poll
/// [getExport] until it is ready, then [openExportDownload].
extension SlimmApiExports on SlimmApi {
  /// Your own exports, newest first.
  Future<List<DataExport>> listExports() async {
    final json = await send('GET', '/exports');
    return [
      for (final e in json as List<dynamic>)
        DataExport.fromJson(e as Map<String, dynamic>),
    ];
  }

  /// Starts an export of the caller's own data. [password] is the caller's own.
  Future<DataExport> startMemberExport({required String password}) async {
    final json = await send(
      'POST',
      '/exports/member',
      body: {'password': password},
    );
    return DataExport.fromJson(json as Map<String, dynamic>);
  }

  /// Starts an export of the whole space. Requires ADMINISTRATOR.
  Future<DataExport> startSpaceExport({required String password}) async {
    final json = await send(
      'POST',
      '/exports/space',
      body: {'password': password},
    );
    return DataExport.fromJson(json as Map<String, dynamic>);
  }

  Future<DataExport> getExport(String exportId) async {
    final json = await send('GET', '/exports/$exportId');
    return DataExport.fromJson(json as Map<String, dynamic>);
  }

  /// Deletes an export and its archive now; a running one is cancelled.
  Future<void> deleteExport(String exportId) =>
      send('DELETE', '/exports/$exportId', expectNoContent: true);

  /// Streams a finished archive, with no deadline on the body.
  Future<AttachmentDownload> openExportDownload(String exportId) =>
      openDownload('/exports/$exportId/download', null);
}
