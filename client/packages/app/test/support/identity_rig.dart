// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A loopback slim-m server and a signed-in session against it, for the
/// identity gate's tests: what it records is what would reach a real server.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
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

const identityKeyA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const identityKeyB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';

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

enum VersionAnswer { answers, serverError, notFoundPage, hangsUp }

/// How the server meets the identity challenge.
enum ProofAnswer {
  /// 404, as a server older than the challenge does.
  absent,

  /// Signs it with [IdentityServer.keyPair].
  signs,

  /// Answers with a signature no key made, as a host that only copied the key can.
  forges,
}

class IdentityServer {
  late final HttpServer http;
  final sockets = <WebSocket>[];

  String? presentedKey = identityKeyA;
  VersionAnswer probe = VersionAnswer.answers;
  ProofAnswer proof = ProofAnswer.absent;
  SimpleKeyPair? keyPair;
  var proofsAsked = 0;
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
    if (path == '/identity/proof') return _proof(req);
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
      case VersionAnswer.hangsUp:
        final socket = await req.response.detachSocket();
        socket.destroy();
        return;
      case VersionAnswer.serverError:
        req.response.statusCode = 500;
        await req.response.close();
        return;
      case VersionAnswer.notFoundPage:
        req.response.statusCode = 404;
        req.response.headers.contentType = ContentType.html;
        req.response.write('<html>Not found</html>');
        await req.response.close();
        return;
      case VersionAnswer.answers:
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

  /// Gives the server a real Ed25519 key that it presents and signs with.
  Future<String> useRealKey() async {
    final pair = await Ed25519().newKeyPair();
    keyPair = pair;
    proof = ProofAnswer.signs;
    final key = base64.encode((await pair.extractPublicKey()).bytes);
    presentedKey = key;
    return key;
  }

  Future<void> _proof(HttpRequest req) async {
    proofsAsked++;
    final body = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
    if (proof == ProofAnswer.absent) {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }
    final challenge = base64.decode(body['challenge'] as String);
    final signed = [...identityProofContext, ...challenge];
    final signature = proof == ProofAnswer.signs
        ? (await Ed25519().sign(signed, keyPair: keyPair!)).bytes
        : List<int>.filled(64, 7);
    req.response.headers.contentType = ContentType.json;
    req.response.write(
      jsonEncode({
        'public_key': presentedKey,
        'signature': base64.encode(signature),
      }),
    );
    await req.response.close();
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

class _NoJitter implements Random {
  @override
  int nextInt(int max) => 0;
  @override
  double nextDouble() => 0;
  @override
  bool nextBool() => false;
}

class IdentityRig {
  IdentityRig(this.server, this.container, this.keys);

  final IdentityServer server;
  final ProviderContainer container;
  final InMemoryKeyStore keys;

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

  /// Live and done re-asking the identity, so a key changed after this is seen only by the next live edge.
  Future<void> untilLiveAndRechecked() async {
    await untilLive();
    await until(
      () =>
          server.versionReads >= 2 &&
          server.versionsAnswered == server.versionReads,
      'rechecked on going live',
    );
    await container.read(serverIdentityChangeProvider.future);
  }

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

/// A signed-in session against a loopback [IdentityServer], with [pinned]
/// stored for it; [realKey] gives the server a key it can prove, and pins it.
Future<IdentityRig> identityRig({
  String? pinned = identityKeyA,
  bool realKey = false,
}) async {
  final server = IdentityServer();
  await server.start();
  if (realKey) pinned = await server.useRealKey();
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
      versionRetryDelaysProvider.overrideWithValue(const []),
      // A loaded CI runner can stack a few failed connects into a backoff past the wait budget.
      syncControllerProvider.overrideWith(
        (ref) => SyncController(
          ref,
          random: _NoJitter(),
          backoffStep: const Duration(milliseconds: 20),
        ),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(() async {
    for (final socket in List.of(server.sockets)) {
      await socket.close();
    }
  });
  return IdentityRig(server, container, keys);
}
