// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a reply whose size a server nobody vouched for decides.
library;

import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'exceptions.dart';

/// The most an unvouched server's JSON reply may hold before it is refused.
const unvouchedReplyBytes = 256 * 1024;

/// Reads [response] whole, or throws [UnreadableReplyException] once it
/// declares or delivers more than [maxBytes]; null reads without a bound.
Future<http.Response> readBoundedReply(
  http.StreamedResponse response,
  int? maxBytes,
) async {
  if (maxBytes == null) return http.Response.fromStream(response);
  if ((response.contentLength ?? 0) > maxBytes) {
    await response.stream.listen(null).cancel();
    throw _tooLarge(maxBytes);
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in response.stream) {
    body.add(chunk);
    if (body.length > maxBytes) throw _tooLarge(maxBytes);
  }
  return http.Response.bytes(
    body.takeBytes(),
    response.statusCode,
    request: response.request,
    headers: response.headers,
    isRedirect: response.isRedirect,
    persistentConnection: response.persistentConnection,
    reasonPhrase: response.reasonPhrase,
  );
}

UnreadableReplyException _tooLarge(int maxBytes) =>
    UnreadableReplyException('the reply was larger than $maxBytes bytes');
