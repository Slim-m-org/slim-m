// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:slimm_api/api.dart';
import 'package:slimm_test_support/slimm_test_support.dart';
import 'package:test/test.dart';

void main() {
  test('a fixture route answers its JSON and records the call', () async {
    final server = FakeSlimmServer()
      ..respond('GET', '/channels', [
        {
          'id': 'c1',
          'name': 'general',
          'kind': 'text',
          'position': 0,
          'created_at': 1,
        },
      ]);

    final channels = await server.api().listChannels();

    expect(channels.single.name, 'general');
    expect(server.requestsTo('GET', '/channels'), hasLength(1));
    expect(server.unmatched, isEmpty);
  });

  test('path parameters are bound and the newest route wins', () async {
    final server = FakeSlimmServer()
      ..respond('DELETE', '/channels/:id', null, status: 500)
      ..on('DELETE', '/channels/:id', (request) {
        expect(request.params['id'], 'c9');
        return FakeReply.status(204);
      });

    await server.api().deleteChannel('c9');

    expect(server.requestsTo('DELETE', '/channels/:id'), hasLength(1));
  });

  test('an unrouted request is answered 404 and recorded', () async {
    final server = FakeSlimmServer();

    await expectLater(server.api().listChannels(), throwsA(anything));

    expect(server.unmatched.single.path, '/channels');
  });
}
