// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [RootFetchingClient]: the Windows token exchange that failed with
/// CERTIFICATE_VERIFY_FAILED until Windows had fetched Spotify's root.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_app/src/spotify/root_fetching_client.dart';

const _unknownIssuer = HandshakeException(
  'Handshake error in client',
  OSError(
    'CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate',
    1,
  ),
);

class _Rig {
  _Rig(List<Object> outcomes) : _outcomes = outcomes;

  final List<Object> _outcomes;
  final fetched = <String>[];
  final contexts = <SecurityContext?>[];
  final bodies = <String>[];

  late final client = RootFetchingClient(
    fetchRoots: (host) async => fetched.add(host),
    build: (context) {
      contexts.add(context);
      return MockClient((request) async {
        bodies.add(request.body);
        final next = _outcomes.removeAt(0);
        if (next is Exception) throw next;
        return http.Response('$next', 200);
      });
    },
  );
}

final _token = Uri.https('accounts.spotify.com', '/api/token');

void main() {
  test('an unknown issuer has Windows fetch the root, then the same request '
      'is sent again over a context that reads the store afresh', () async {
    final rig = _Rig([_unknownIssuer, 'tokens']);

    final reply = await rig.client.post(_token, body: {'code': 'c'});

    expect(reply.body, 'tokens');
    expect(rig.fetched, ['accounts.spotify.com']);
    expect(rig.contexts, hasLength(2));
    expect(rig.contexts.first, isNull);
    expect(rig.contexts.last, isNotNull);
    expect(rig.bodies, ['code=c', 'code=c']);
  });

  test('a host is fetched for once, so a root Windows lacks too fails fast '
      'instead of looping', () async {
    final rig = _Rig([_unknownIssuer, _unknownIssuer, _unknownIssuer]);

    await expectLater(
      rig.client.post(_token, body: {'code': 'c'}),
      throwsA(isA<HandshakeException>()),
    );
    await expectLater(
      rig.client.post(_token, body: {'code': 'c'}),
      throwsA(isA<HandshakeException>()),
    );

    expect(rig.fetched, ['accounts.spotify.com']);
  });

  test('other handshake failures are not a missing root', () async {
    final rig = _Rig([
      const HandshakeException('Connection terminated during handshake'),
    ]);

    await expectLater(
      rig.client.get(_token),
      throwsA(isA<HandshakeException>()),
    );

    expect(rig.fetched, isEmpty);
  });
}
