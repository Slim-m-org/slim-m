// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A server whose key contradicts its pin gets no signed-in request and no
/// socket until the person chooses (decision 0036).
///
/// The real api client and sync controller run against a loopback server, so
/// what it records is what would have reached a real one.
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/providers/server_identity_recheck.dart';
import 'package:slimm_app/src/features/auth/providers/server_version_probe.dart';
import 'package:slimm_app/src/features/auth/widgets/server_identity_confirmation.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';

const _keyA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _keyB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

Map<String, dynamic> _identity(String key) => {
  'public_key': key,
  'fingerprint': 'deadbeefcafebabefeedface1337d00d',
  'fingerprint_groups': ['dead', 'beef', 'cafe', 'babe'],
  'color_strip': [0, 1, 2, 3],
};

enum _Probe { answers, serverError, hangsUp }

class _Server {
  late final HttpServer http;
  final sockets = <WebSocket>[];

  String? presentedKey = _keyA;
  _Probe probe = _Probe.answers;
  Duration versionDelay = Duration.zero;

  var versionReads = 0;
  var versionsAnswered = 0;
  var versionsAnsweredAtFirstSignedIn = -1;
  var socketsOpened = 0;
  var versionReadsAtFirstSignedIn = -1;
  final signedIn = <String>[];
  final bearers = <String>{};

  Uri get url => Uri.parse('http://127.0.0.1:${http.port}');

  Future<void> start() async {
    http = await HttpServer.bind('127.0.0.1', 0);
    http.listen(_handle);
  }

  Future<void> _handle(HttpRequest req) async {
    final path = req.uri.path;
    if (path == '/ws') return _socket(req);
    if (path == '/version') return _version(req);
    final bearer = req.headers.value('authorization');
    if (bearer != null) {
      if (signedIn.isEmpty) {
        versionReadsAtFirstSignedIn = versionReads;
        versionsAnsweredAtFirstSignedIn = versionsAnswered;
      }
      signedIn.add('${req.method} $path');
      bearers.add(bearer);
    }
    Object body = <Object>[];
    if (path == '/auth/ws-ticket') {
      body = {'ticket': 't', 'expires_at': 9999999999};
    } else if (path == '/sync') {
      body = {'scopes': <Object>[]};
    }
    await utf8.decoder.bind(req).drain<void>();
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(body));
    await req.response.close();
  }

  Future<void> _version(HttpRequest req) async {
    versionReads++;
    switch (probe) {
      case _Probe.hangsUp:
        final socket = await req.response.detachSocket();
        socket.destroy();
        return;
      case _Probe.serverError:
        req.response.statusCode = 500;
        await req.response.close();
        return;
      case _Probe.answers:
        await Future<void>.delayed(versionDelay);
        req.response.headers.contentType = ContentType.json;
        req.response.write(
          jsonEncode({
            'name': 'slim-m',
            'version': '1.0.0',
            'protocol': protocolVersion,
            if (presentedKey case final key?) 'identity': _identity(key),
          }),
        );
        await req.response.close();
        versionsAnswered++;
    }
  }

  Future<void> _socket(HttpRequest req) async {
    socketsOpened++;
    final ws = await WebSocketTransformer.upgrade(req);
    sockets.add(ws);
    ws.listen((raw) {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      if (frame['type'] != 'hello') return;
      ws.add(jsonEncode({'type': 'hello', 'protocol': protocolVersion}));
    }, onDone: () => sockets.remove(ws));
  }
}

class _Rig {
  _Rig(this.server, this.container);

  final _Server server;
  final ProviderContainer container;

  SyncStatus get status => container.read(syncControllerProvider);

  Future<void> until(bool Function() done, String what) async {
    for (var i = 0; i < 400; i++) {
      if (done()) return;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    fail('never $what');
  }

  Future<void> untilLive() =>
      until(() => status == SyncStatus.live, 'went live');

  /// Long enough that a request which was going to be sent would have been.
  Future<void> quiet() =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  Future<void> trustPresentedKey() async {
    final mismatch = await container.read(serverIdentityChangeProvider.future);
    await container
        .read(serverIdentityChangeProvider.notifier)
        .trust(mismatch!.presented!);
  }
}

Future<_Rig> _rig({String? pinned = _keyA}) async {
  final server = _Server();
  await server.start();
  addTearDown(() => server.http.close(force: true));
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  final session = SessionStore(tokens: _tokens);
  final keys = InMemoryKeyStore();
  if (pinned != null) {
    await keys.put(identityHandleFor(server.url), pinned);
  }
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keys),
      sessionProvider.overrideWithValue(session),
      serverUrlProvider.overrideWith((ref) => server.url),
      storeProvider.overrideWith((ref) async => store),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() async {
    for (final socket in List.of(server.sockets)) {
      await socket.close();
    }
  });
  return _Rig(server, container);
}

void main() {
  test(
    'a changed key gets no signed-in request and no socket until trusted',
    () async {
      final rig = await _rig();
      rig.server.presentedKey = _keyB;
      rig.container.read(syncControllerProvider.notifier);

      final mismatch = await rig.container.read(
        serverIdentityChangeProvider.future,
      );
      expect(mismatch, isNotNull);
      await rig.quiet();

      expect(rig.server.signedIn, isEmpty);
      expect(rig.server.socketsOpened, 0);
      expect(rig.status, isNot(SyncStatus.live));

      await rig.trustPresentedKey();
      await rig.untilLive();

      expect(rig.server.signedIn, contains('POST /auth/ws-ticket'));
      expect(rig.server.bearers, {'Bearer access-1'});
      expect(rig.server.socketsOpened, 1);
    },
  );

  test('a pinned server that reports no key is held until accepted', () async {
    final rig = await _rig();
    rig.server.presentedKey = null;
    rig.container.read(syncControllerProvider.notifier);

    await rig.container.read(serverIdentityChangeProvider.future);
    await rig.quiet();
    expect(rig.server.signedIn, isEmpty);
    expect(rig.server.socketsOpened, 0);

    rig.container
        .read(serverIdentityChangeProvider.notifier)
        .acceptMissingIdentity();
    await rig.untilLive();
    expect(rig.server.bearers, {'Bearer access-1'});
  });

  test('a /version that errors lets the session through', () async {
    final rig = await _rig();
    rig.server.probe = _Probe.serverError;
    rig.container.read(syncControllerProvider.notifier);

    await rig.untilLive();

    expect(rig.server.versionReads, greaterThan(0));
    expect(rig.server.bearers, {'Bearer access-1'});
  });

  test('a /version that hangs up lets the session through', () async {
    final rig = await _rig();
    rig.server.probe = _Probe.hangsUp;
    rig.container.read(syncControllerProvider.notifier);

    await rig.untilLive();

    expect(rig.server.versionReads, greaterThan(0));
    expect(rig.server.bearers, {'Bearer access-1'});
  });

  test(
    'a matching pin waits for one /version answer and adds no second',
    () async {
      final rig = await _rig();
      rig.server.versionDelay = const Duration(milliseconds: 300);
      rig.container.read(syncControllerProvider.notifier);

      await rig.untilLive();

      expect(rig.server.versionReadsAtFirstSignedIn, 1);
      expect(rig.server.versionsAnsweredAtFirstSignedIn, 1);
    },
  );

  test('nothing pinned yet is not held for a /version read', () async {
    final rig = await _rig(pinned: null);
    rig.server.probe = _Probe.serverError;
    rig.container.read(syncControllerProvider.notifier);

    await rig.untilLive();

    expect(rig.server.versionReadsAtFirstSignedIn, 0);
  });

  test('a key that changes mid-session stops sync instead of looping, and '
      'trusting it restarts', () async {
    final rig = await _rig();
    rig.container.read(syncControllerProvider.notifier);
    await rig.untilLive();
    final before = rig.server.signedIn.length;
    expect(rig.server.socketsOpened, 1);

    rig.server.presentedKey = _keyB;
    rig.container.invalidate(serverVersionProbeProvider);
    await rig.until(
      () =>
          rig.container.read(serverIdentityChangeProvider).valueOrNull != null,
      'proved the mismatch',
    );
    await rig.until(() => rig.status == SyncStatus.offline, 'stood down');
    await rig.quiet();

    expect(rig.server.socketsOpened, 1);
    expect(rig.server.signedIn.length, before);
    expect(rig.server.sockets, isEmpty);

    await rig.trustPresentedKey();
    await rig.untilLive();

    expect(rig.server.socketsOpened, 2);
    expect(rig.server.signedIn.length, greaterThan(before));
  });

  test('a call made while a key is in question waits for the choice', () async {
    final rig = await _rig();
    rig.server.presentedKey = _keyB;
    final api = rig.container.read(apiProvider);

    var answered = false;
    final channels = api.listChannels().then((_) => answered = true);
    await rig.container.read(serverIdentityChangeProvider.future);
    await rig.quiet();
    expect(answered, isFalse);
    expect(rig.server.signedIn, isEmpty);

    await rig.trustPresentedKey();
    await channels;
    expect(rig.server.signedIn, contains('GET /channels'));
  });
}
