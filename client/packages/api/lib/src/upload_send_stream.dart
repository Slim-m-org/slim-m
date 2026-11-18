// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sends an upload by streaming its body into the request, counting bytes as
/// the request takes them.
library;

import 'dart:async';

import 'package:http/http.dart' as http;

/// Pipes [body] into [request] and sends it through [client], calling
/// [onProgress] with the running count as each chunk is handed over.
Future<http.StreamedResponse> sendStreamingUpload(
  http.Client client,
  http.StreamedRequest request,
  Stream<List<int>> body, {
  void Function(int sent)? onProgress,
}) {
  var sent = 0;
  final counted = body.map((chunk) {
    sent += chunk.length;
    onProgress?.call(sent);
    return chunk;
  });
  unawaited(
    request.sink
        .addStream(counted)
        .then((_) => request.sink.close())
        .catchError((Object e, StackTrace st) {
      request.sink.addError(e, st);
      request.sink.close();
    }),
  );
  return client.send(request);
}
