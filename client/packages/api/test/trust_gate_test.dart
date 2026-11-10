// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// While a trust gate holds the session, no call that carries it reaches the
/// server; once it lets go, every one does with the bearer attached.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _rotated = {
  'user_id': 'user-1',
  'access_token': 'access-2',
  'refresh_token': 'refresh-2',
  'access_expires_at': 0,
};

class _Rig {
  _Rig() {
    api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      trustGate: () {
        asked++;
        return open ? null : release.future;
      },
      httpClient: MockClient.streaming((request, body) async {
        sent.add('${request.method} ${request.url.path}');
        carried.add(request.headers['authorization'] ?? '');
        await body.drain<void>();
        final reply = switch (request.url.path) {
          '/auth/refresh' => jsonEncode(_rotated),
          '/auth/ws-ticket' => jsonEncode({'ticket': 't', 'expires_at': 0}),
          '/channels' => '[]',
          '/version' => jsonEncode({
              'name': 'slim-m',
              'version': '1.0.0',
              'protocol': 1,
            }),
          _ => '{}',
        };
        return http.StreamedResponse(
          Stream.value(utf8.encode(reply)),
          200,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
  }

  late final SlimmApi api;
  final release = Completer<void>();
  final sent = <String>[];
  final carried = <String>[];
  var open = false;
  var asked = 0;

  void let() {
    open = true;
    release.complete();
  }

  Future<void> settle() async {
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }
}

Stream<List<int>> _bytes() => Stream.value([1, 2, 3]);

/// Every way the client sends the session; a new one belongs in here.
final _calls = <String, Future<Object?> Function(SlimmApi)>{
  'a plain request': (api) => api.listChannels(),
  'the websocket ticket': (api) => api.webSocketTicket(),
  'a byte fetch': (api) => api.fetchAttachment('a1'),
  'a download': (api) => api.openAttachmentDownload('a1'),
  'a streamed upload': (api) => api.sendStreamed(
        'POST',
        '/attachments',
        open: _bytes,
        length: 3,
      ),
  'a diagnostics download': (api) => api.connectionProbes().last.$2.download(3),
  'a diagnostics upload': (api) => api.connectionProbes().last.$2.upload(3),
  'a diagnostics ping': (api) => api.connectionProbes().last.$2.ping(),
};

void main() {
  for (final MapEntry(key: name, value: call) in _calls.entries) {
    test('$name waits for the gate, then goes out with the session', () async {
      final rig = _Rig();
      final done = call(rig.api);

      await rig.settle();
      expect(rig.sent, isEmpty, reason: 'nothing may be sent while held');

      rig.let();
      await done;
      expect(rig.carried, ['Bearer access-1']);
    });
  }

  test('a refresh holds the refresh token back too', () async {
    final rig = _Rig();
    final done = rig.api.refresh();

    await rig.settle();
    expect(rig.sent, isEmpty);

    rig.let();
    await done;
    expect(rig.sent, ['POST /auth/refresh']);
    expect(rig.api.session.tokens?.accessToken, 'access-2');
  });

  test('a call that carries no session is not held', () async {
    final rig = _Rig();
    await rig.api.version();
    expect(rig.sent, ['GET /version']);
    expect(rig.asked, 0);
  });

  test('a gate that does not hold adds no wait', () async {
    final rig = _Rig()..let();
    await rig.api.listChannels();
    expect(rig.sent, ['GET /channels']);
    expect(rig.asked, 1);
  });

  test('a client with no gate sends straight away', () async {
    final sent = <String>[];
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: SessionStore(tokens: _tokens),
      httpClient: MockClient((request) async {
        sent.add(request.url.path);
        return http.Response('[]', 200);
      }),
    );
    await api.listChannels();
    expect(sent, ['/channels']);
  });

  test('a session cleared while held sends nothing', () async {
    final rig = _Rig();
    final done = expectLater(
      rig.api.listChannels(),
      throwsA(isA<UnauthorizedException>()),
    );

    await rig.settle();
    rig.api.session.clear();
    rig.let();

    await done;
    expect(rig.sent, isEmpty);
  });
}
