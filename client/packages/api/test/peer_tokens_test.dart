// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tabs on one cookie session share the access token a rotation mints (decision 0141).
///
/// A rotation kills the session's earlier access tokens, so a tab that rotated for itself would sign the others out.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

final _base = Uri.parse('https://chat.example');
final _farFuture = DateTime.now().millisecondsSinceEpoch + 600000;

/// One server whose rotation kills the earlier access token, like the real one.
class _Server {
  var live = 'access-0';
  var rotations = 0;

  http.Response handle(http.Request request) {
    if (request.url.path == '/auth/refresh') {
      rotations++;
      live = 'access-$rotations';
      return _json({
        'user_id': 'u1',
        'access_token': live,
        'access_expires_at': _farFuture + rotations,
      });
    }
    return request.headers['authorization'] == 'Bearer $live'
        ? _json(<Object>[])
        : _json({'error': 'unauthorized'}, 401);
  }
}

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

/// One tab's side of an in-process BroadcastChannel.
class _Peer implements PeerTokens {
  _Peer(this._bus) {
    _bus.add(this);
  }

  final List<_Peer> _bus;
  late SessionStore session;
  TokenPair? _newest;
  var asked = 0;

  @override
  TokenPair? get newest => _newest;

  @override
  void announce(TokenPair tokens) {
    for (final peer in _bus.where((p) => p != this)) {
      peer._newest = tokens;
    }
  }

  @override
  Future<TokenPair?> ask() async {
    asked++;
    for (final peer in _bus.where((p) => p != this)) {
      final held = peer.session.tokens;
      if (held != null && held.accessToken.isNotEmpty) return held;
    }
    return null;
  }
}

({SlimmApi api, _Peer peer}) _tab(
  _Server server,
  List<_Peer> bus, {
  required String access,
  int expires = 0,
}) {
  final peer = _Peer(bus);
  final session = SessionStore(
    tokens: TokenPair(
      userId: 'u1',
      accessToken: access,
      refreshToken: '',
      accessExpiresAt: expires,
    ),
    peers: peer,
  );
  peer.session = session;
  final api = SlimmApi(
    baseUrl: _base,
    session: session,
    webSession: true,
    httpClient: MockClient((request) async => server.handle(request)),
  );
  return (api: api, peer: peer);
}

void main() {
  test(
      'a tab whose token another tab rotated away takes the peer token, not '
      'a rotation of its own', () async {
    final server = _Server();
    final bus = <_Peer>[];
    final a = _tab(server, bus, access: 'access-0', expires: _farFuture - 1);
    final b = _tab(server, bus, access: 'access-0', expires: _farFuture - 1);

    server.live = 'expired';
    await a.api.refresh();
    expect(server.rotations, 1);

    expect(await b.api.listChannels(), isEmpty);
    expect(server.rotations, 1, reason: 'B adopted A\'s token');
    expect(b.api.session.tokens?.accessToken, 'access-1');
  });

  test(
      'a tab opened after a reload asks the others for a live token before '
      'rotating', () async {
    final server = _Server()..live = 'access-7';
    final bus = <_Peer>[];
    _tab(server, bus, access: 'access-7', expires: _farFuture);
    final fresh = _tab(server, bus, access: '');

    expect(await fresh.api.listChannels(), isEmpty);

    expect(fresh.peer.asked, 1);
    expect(server.rotations, 0);
  });

  test('a peer token that is not newer than the held one is not adopted',
      () async {
    final server = _Server();
    final bus = <_Peer>[];
    final a = _tab(server, bus, access: 'access-0', expires: _farFuture - 1);
    final b = _tab(server, bus, access: 'stale', expires: _farFuture + 100000);

    await a.api.refresh();
    await b.api.refresh();

    expect(server.rotations, 2);
  });

  test('a tab with nobody to ask rotates for itself', () async {
    final server = _Server();
    final lone = _tab(server, [], access: '');

    expect(await lone.api.listChannels(), isEmpty);

    expect(server.rotations, 1);
  });
}
