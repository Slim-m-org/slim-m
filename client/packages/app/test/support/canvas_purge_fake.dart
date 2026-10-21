// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The server's `DELETE .../canvas/objects/{id}` for a fake HTTP handler.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

/// Answers a canvas Delete the way the server does: the object's last row, or 404 once it is gone.
/// A [status] other than 200 refuses every call with it.
http.Response fakePurge(
  http.Request request,
  Set<String> serverObjects, {
  int status = 200,
  List<String>? purged,
}) {
  final id = request.url.pathSegments.last;
  if (status != 200) return _json({'error': 'nope'}, status);
  if (!serverObjects.remove(id)) return _json({'error': 'not found'}, 404);
  purged?.add(id);
  return _json({
    'id': id,
    'kind': 'stroke',
    'z_index': 1,
    'x': 100.0,
    'y': 100.0,
    'w': 40.0,
    'h': 0.0,
    'props': {
      'points': [0.0, 0.0, 40.0, 0.0],
      'width': 4.0,
      'color': 'annotation',
    },
    'author_id': 'me',
    'seq': 9,
    'created_at': 0,
  }, 200);
}

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

bool isPurge(http.Request request) => request.method == 'DELETE';
