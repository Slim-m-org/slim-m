// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Off the web an upload streams, so bytes handed to the socket are bytes sent.
library;

import 'package:http/http.dart' as http;

import 'upload_send_stream.dart';

/// Sends [request] with [body], reporting progress through [onProgress].
Future<http.StreamedResponse> sendUpload(
  http.Client client,
  http.StreamedRequest request,
  Stream<List<int>> body, {
  void Function(int sent)? onProgress,
}) =>
    sendStreamingUpload(client, request, body, onProgress: onProgress);
