// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `POST /channels/{id}/canvas/export` and the `canvas_export` capability.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

SlimmApi _api(MockClientHandler handler) => SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(
        tokens: const TokenPair(
          userId: 'me',
          accessToken: 'a',
          refreshToken: 'r',
          accessExpiresAt: 0,
        ),
      ),
      httpClient: MockClient(handler),
    );

const _json = {'content-type': 'application/json'};

void main() {
  test('exportCanvas sends the id, the name and every choice', () async {
    http.Request? seen;
    final api = _api((request) async {
      seen = request;
      return http.Response(
        jsonEncode({
          'channel': {
            'id': 'new',
            'name': 'minecraft canvas',
            'kind': 'canvas',
            'created_at': 5,
          },
          'copied': 12,
          'skipped': 1,
          'cleared': 11,
          'spared': 1,
          'later_field': true,
        }),
        200,
        headers: _json,
      );
    });

    final result = await api.exportCanvas(
      'board',
      id: 'new',
      name: 'minecraft canvas',
      categoryId: null,
      voiceEnabled: true,
      clearSource: true,
    );

    expect(seen!.method, 'POST');
    expect(seen!.url.path, '/channels/board/canvas/export');
    expect(jsonDecode(seen!.body), {
      'id': 'new',
      'name': 'minecraft canvas',
      'category_id': null,
      'voice_enabled': true,
      'clear_source': true,
    });
    expect(result.channel.id, 'new');
    expect(result.channel.isCanvasChannel, isTrue);
    expect(
      (result.copied, result.skipped, result.cleared, result.spared),
      (12, 1, 11, 1),
    );
  });

  test('a refusal carries its code on the conflict', () async {
    final api = _api(
      (request) async => http.Response(
        jsonEncode({
          'error': 'This canvas is too big to export.',
          'code': CanvasExportRefusal.tooLarge,
        }),
        409,
        headers: _json,
      ),
    );

    await expectLater(
      api.exportCanvas('board', id: 'new', name: 'x', categoryId: 'c'),
      throwsA(
        isA<ConflictException>().having(
          (e) => e.code,
          'code',
          'canvas_export_too_large',
        ),
      ),
    );
  });

  test('canvas_export on /version turns the capability on', () {
    final on = Version.fromJson({
      'name': 's',
      'version': '1',
      'protocol': 1,
      'capabilities': ['canvas_export'],
    });
    final off = Version.fromJson({'name': 's', 'version': '1', 'protocol': 1});
    expect((on.supportsCanvasExport, off.supportsCanvasExport), (true, false));
  });
}
