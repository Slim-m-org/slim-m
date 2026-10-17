// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `GET /channels/{channelId}/overwrites`: the read an
/// editor needs to see what it is replacing.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('http://localhost:8080');

TokenPair _tokens() => const TokenPair(
      userId: 'u1',
      accessToken: 'access',
      refreshToken: 'refresh',
      accessExpiresAt: 0,
    );

void main() {
  test('ChannelOverwrite.fromJson parses every field', () {
    final overwrite = ChannelOverwrite.fromJson({
      'kind': 'role',
      'id': 'role-1',
      'allow': 1,
      'deny': 2,
    });
    expect(overwrite.kind, OverwriteTarget.role);
    expect(overwrite.id, 'role-1');
    expect(overwrite.allow, 1);
    expect(overwrite.deny, 2);
  });

  test('ChannelOverwrite.fromJson parses the member kind too', () {
    final overwrite = ChannelOverwrite.fromJson({
      'kind': 'member',
      'id': 'user-1',
      'allow': 0,
      'deny': 4,
    });
    expect(overwrite.kind, OverwriteTarget.member);
    expect(overwrite.id, 'user-1');
  });

  test('an unrecognised kind reads as member, not a throw', () {
    final overwrite = ChannelOverwrite.fromJson({
      'kind': 'something-new',
      'id': 'x',
      'allow': 0,
      'deny': 0,
    });
    expect(overwrite.kind, OverwriteTarget.member);
  });

  test(
      'getChannelOverwrites GETs the channel-scoped path and unwraps the '
      'array', () async {
    http.Request? sent;
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient((request) async {
        sent = request;
        return http.Response(
          jsonEncode({
            'overwrites': [
              {'kind': 'role', 'id': 'r1', 'allow': 1, 'deny': 0},
              {'kind': 'member', 'id': 'm1', 'allow': 0, 'deny': 8},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(api.close);

    final overwrites = await api.getChannelOverwrites('c1');
    expect(sent!.method, 'GET');
    expect(sent!.url.path, '/channels/c1/overwrites');
    expect(overwrites, hasLength(2));
    expect(overwrites[0].kind, OverwriteTarget.role);
    expect(overwrites[0].id, 'r1');
    expect(overwrites[0].allow, 1);
    expect(overwrites[1].kind, OverwriteTarget.member);
    expect(overwrites[1].deny, 8);
  });

  test('a channel with nothing set parses to an empty list, not a throw',
      () async {
    final api = SlimmApi(
      baseUrl: _base,
      session: SessionStore(tokens: _tokens()),
      httpClient: MockClient(
        (_) async => http.Response(
          jsonEncode({'overwrites': const <Object>[]}),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(api.close);

    expect(await api.getChannelOverwrites('c1'), isEmpty);
  });
}
