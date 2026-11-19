// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every browser tab of one profile shares one session, so each tab's voice
/// requests carry the tab's own id: a second tab is warned of the first tab's
/// call before its join takes it, and the first tab, reloaded, still owns
/// what it left behind. Driven through the real api client over a local
/// server that answers `this_device` the way the server does.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/voice/providers/voice_elsewhere.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _Tab implements CrossTab {
  _Tab(this.tabId);

  @override
  final String? tabId;

  @override
  Future<T> exclusive<T>(String name, Future<T> Function() body) => body();

  @override
  Stream<void> get storageChanges => const Stream.empty();

  @override
  Future<bool> anotherTabIsOpen() async => true;
}

/// A room holding this account's call, joined from the tab named [joinedFrom].
Future<HttpServer> _roomJoinedFrom(String joinedFrom) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((request) async {
    final asked = request.uri.queryParameters['tab'];
    final found = request.uri.path == '/channels/c1/voice/roster';
    request.response
      ..statusCode = found ? 200 : 404
      ..headers.contentType = ContentType.json
      ..write(
        jsonEncode({
          'participants': [
            {
              'user_id': 'self',
              'display_name': 'Self',
              'is_sharing_screen': false,
              'has_video': false,
              'is_muted': false,
              'is_deafened': false,
              'this_device': asked == joinedFrom,
            },
          ],
          'call_age_ms': 1000,
        }),
      );
    await request.response.close();
  });
  return server;
}

/// What the other-device check answers on the tab [tab] about to join `c1`.
Future<String?> _elsewhereFrom(String tab) async {
  final server = await _roomJoinedFrom('first');
  addTearDown(() => server.close(force: true));
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      serverUrlProvider.overrideWithValue(
        Uri.parse('http://127.0.0.1:${server.port}'),
      ),
      crossTabProvider.overrideWithValue(_Tab(tab)),
      voiceFlagsProvider.overrideWithValue(const VoiceFlags()),
    ],
  );
  addTearDown(container.dispose);
  return container.read(voiceElsewhereCheckProvider)('c1');
}

void main() {
  test('a second tab is warned of the first tab\'s call', () async {
    expect(await _elsewhereFrom('second'), 'c1');
  });

  test(
    'the first tab, reloaded, still treats its leftover as its own',
    () async {
      expect(await _elsewhereFrom('first'), isNull);
    },
  );
}
