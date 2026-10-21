// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The data export routes: start, status, list, delete and the archive stream.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

Map<String, Object?> _job({String status = 'running', int processed = 5}) => {
      'id': 'e1',
      'kind': 'member',
      'status': status,
      'processed': processed,
      'total': 20,
      'size_bytes': null,
      'error': null,
      'created_at': 10,
      'finished_at': null,
      'expires_at': null,
    };

void main() {
  test('starting a member export sends the password and reads the job',
      () async {
    final api = testApi((request) async {
      expect(request.method, 'POST');
      expect(request.url.path, '/exports/member');
      expect(jsonDecode(request.body), {'password': 'pw'});
      return http.Response(jsonEncode(_job(status: 'queued')), 202);
    });
    final job = await api.startMemberExport(password: 'pw');
    expect(job.kind, ExportKind.member);
    expect(job.status, ExportStatus.queued);
    expect(job.status.isActive, isTrue);
  });

  test('a space export is its own route', () async {
    final api = testApi((request) async {
      expect(request.url.path, '/exports/space');
      return http.Response(jsonEncode(_job()..['kind'] = 'space'), 202);
    });
    expect((await api.startSpaceExport(password: 'pw')).kind, ExportKind.space);
  });

  test('progress is a fraction once the total is known', () {
    expect(DataExport.fromJson(_job()).fraction, 0.25);
    final unknown = _job()
      ..['processed'] = 0
      ..['total'] = 0;
    expect(DataExport.fromJson(unknown).fraction, isNull);
  });

  test('a status the client does not know reads as failed', () {
    expect(
      DataExport.fromJson(_job(status: 'from-the-future')).status,
      ExportStatus.failed,
    );
  });

  test('listing, reading and deleting use the export id', () async {
    final seen = <String>[];
    final api = testApi((request) async {
      seen.add('${request.method} ${request.url.path}');
      if (request.method == 'DELETE') return http.Response('', 204);
      final body = request.url.path == '/exports' ? [_job()] : _job();
      return http.Response(jsonEncode(body), 200);
    });
    expect((await api.listExports()).single.id, 'e1');
    expect((await api.getExport('e1')).processed, 5);
    await api.deleteExport('e1');
    expect(seen, ['GET /exports', 'GET /exports/e1', 'DELETE /exports/e1']);
  });

  test('the archive streams from its own path with the bearer token', () async {
    String? path;
    String? auth;
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'u',
          accessToken: 'access-1',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient.streaming((request, _) async {
        path = request.url.path;
        auth = request.headers['authorization'];
        return http.StreamedResponse(
          Stream.value([1, 2, 3]),
          200,
          contentLength: 3,
          headers: {'content-type': 'application/x-tar'},
        );
      }),
    );
    final download = await api.openExportDownload('e1');
    expect(path, '/exports/e1/download');
    expect(auth, 'Bearer access-1');
    expect(download.contentLength, 3);
  });
}
