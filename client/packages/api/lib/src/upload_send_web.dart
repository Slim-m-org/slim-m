// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// In a browser `fetch` takes the whole body before it sends a byte and
/// reports nothing while it uploads, so a progress bar fed from the body read
/// reads 100% at once. An `XMLHttpRequest` reports what the network took.
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/browser_client.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

import 'upload_send_stream.dart';

/// Sends [request] with [body], reporting the bytes the browser has sent.
///
/// Any client but the browser's own (a test's fake, say) keeps the streamed
/// path, so what it sees is what it saw before.
Future<http.StreamedResponse> sendUpload(
  http.Client client,
  http.StreamedRequest request,
  Stream<List<int>> body, {
  void Function(int sent)? onProgress,
}) async {
  if (client is! BrowserClient || onProgress == null) {
    return sendStreamingUpload(client, request, body, onProgress: onProgress);
  }
  final bytes = await _collect(body);
  return _send(request, bytes, onProgress);
}

Future<Uint8List> _collect(Stream<List<int>> body) async {
  final builder = BytesBuilder(copy: false);
  await body.forEach(builder.add);
  return builder.takeBytes();
}

Future<http.StreamedResponse> _send(
  http.StreamedRequest request,
  Uint8List bytes,
  void Function(int sent) onProgress,
) {
  final xhr = web.XMLHttpRequest()
    ..open(request.method, '${request.url}')
    ..responseType = 'arraybuffer';
  request.headers.forEach((name, value) {
    // The browser sets the length itself and refuses a page that tries.
    if (name.toLowerCase() != 'content-length') {
      xhr.setRequestHeader(name, value);
    }
  });
  final done = Completer<http.StreamedResponse>();
  void fail(web.Event _) {
    if (done.isCompleted) return;
    done.completeError(
      http.ClientException('XMLHttpRequest error.', request.url),
    );
  }

  xhr.upload.onprogress = ((web.ProgressEvent event) {
    onProgress(event.loaded);
  }).toJS;
  xhr.onload = ((web.Event _) {
    if (done.isCompleted) return;
    final response = xhr.response;
    final body = response == null
        ? Uint8List(0)
        : (response as JSArrayBuffer).toDart.asUint8List();
    done.complete(
      http.StreamedResponse(
        Stream.value(body),
        xhr.status,
        contentLength: body.length,
        request: request,
        headers: _headers(xhr.getAllResponseHeaders()),
        reasonPhrase: xhr.statusText,
      ),
    );
  }).toJS;
  xhr.onerror = fail.toJS;
  xhr.onabort = fail.toJS;
  xhr.ontimeout = fail.toJS;
  xhr.send(bytes.toJS);
  return done.future;
}

/// `getAllResponseHeaders` is one `name: value` per CRLF-ended line.
Map<String, String> _headers(String raw) {
  final headers = <String, String>{};
  for (final line in raw.split('\r\n')) {
    final colon = line.indexOf(':');
    if (colon <= 0) continue;
    final name = line.substring(0, colon).trim().toLowerCase();
    final value = line.substring(colon + 1).trim();
    headers[name] =
        headers.containsKey(name) ? '${headers[name]}, $value' : value;
  }
  return headers;
}
