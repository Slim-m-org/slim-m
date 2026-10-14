// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The GIF-enabled API stub the desktop composer picker suites share.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';

/// Answers `/version` with [gifSearchEnabled] and a minimal working GIF
/// flow: one trending result on open, one search result, its preview.
api.SlimmApi Function(Ref) pickerApi({required bool gifSearchEnabled}) {
  return (ref) => api.SlimmApi(
    baseUrl: Uri.parse('http://localhost:8080'),
    session: ref.watch(sessionProvider),
    httpClient: MockClient((request) async {
      final path = request.url.path;
      if (request.method == 'GET' && path == '/version') {
        return http.Response(
          jsonEncode({
            'name': 'slim-m',
            'version': '0.39.0',
            'protocol': 1,
            'gif_search_enabled': gifSearchEnabled,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path == '/gifs/trending') {
        return http.Response(
          jsonEncode({
            'results': [
              {
                'id': 'tok-trending',
                'title': 'a trending gif',
                'width': 200,
                'height': 150,
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (request.method == 'GET' && path == '/gifs/preview/tok-trending') {
        return http.Response.bytes(
          base64Decode('R0lGODlhAQABAAAAACH5BAEKAAEALAAAAAABAAEAAAICTAEAOw=='),
          200,
          headers: {'content-type': 'image/gif'},
        );
      }
      return http.Response('{}', 404, headers: {'content-type': 'text/plain'});
    }),
  );
}
