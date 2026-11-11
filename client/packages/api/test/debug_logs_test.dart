// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

Map<String, dynamic> _entry(int id) => {
      'id': id,
      'user_id': 'u1',
      'username': 'nia',
      'display_name': 'Nia',
      'note': 'settings reset',
      'app_version': '0.1.0+1',
      'platform': 'linux',
      'size_bytes': 31,
      'created_at': id,
    };

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

void main() {
  test('submitDebugLog posts the log, note, version and platform', () async {
    late http.Request seen;
    final api = testApi((request) async {
      seen = request;
      return _json({'id': 7, 'created_at': 9}, 201);
    });
    final sent = await api.submitDebugLog(
      log: 'line',
      note: 'it broke',
      appVersion: '0.1.0+1',
      platform: 'linux',
    );
    expect(seen.method, 'POST');
    expect(seen.url.path, '/debug-logs');
    expect(jsonDecode(seen.body), {
      'log': 'line',
      'note': 'it broke',
      'app_version': '0.1.0+1',
      'platform': 'linux',
    });
    expect(sent.id, 7);
  });

  test('listDebugLogs pages with before and limit, keeping the order',
      () async {
    Uri? seen;
    final api = testApi((request) async {
      seen = request.url;
      return _json([_entry(9), _entry(8)]);
    });
    final page = await api.listDebugLogs(before: 10, limit: 2);
    expect(seen?.path, '/debug-logs');
    expect(seen?.queryParameters, {'before': '10', 'limit': '2'});
    expect(page.map((e) => e.id), [9, 8]);
    expect(page.first.displayName, 'Nia');
  });

  test('getDebugLog reads the text and deleteDebugLog sends a DELETE',
      () async {
    final seen = <String>[];
    final api = testApi((request) async {
      seen.add('${request.method} ${request.url.path}');
      return request.method == 'DELETE'
          ? http.Response('', 204)
          : _json({..._entry(3), 'log': 'the text'});
    });
    final log = await api.getDebugLog(3);
    await api.deleteDebugLog(3);
    expect(log.log, 'the text');
    expect(log.entry.sizeBytes, 31);
    expect(seen, ['GET /debug-logs/3', 'DELETE /debug-logs/3']);
  });
}
