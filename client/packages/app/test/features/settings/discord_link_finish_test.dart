// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Finishing a Discord link with the handoff code: how a pasted or delivered
/// code is read, and what the finisher says for each answer the server gives.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/providers/discord_link_finish.dart';
import 'package:slimm_app/src/features/settings/providers/link_finish.dart';
import 'package:slimm_app/src/features/settings/providers/linked_accounts.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _code = 'ABCDEFGHJKLMNPQRSTUVWXYZ2';

const _linked = {
  'provider': 'discord',
  'username': 'nick_d',
  'display_name': 'Nick',
  'linked_at': 1,
};

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Rig {
  _Rig(http.Response Function(http.Request) answer) {
    container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          bodies.add(request.body);
          paths.add(request.url.path);
          return answer(request);
        }),
      ],
    );
  }

  late final ProviderContainer container;
  final bodies = <String>[];
  final paths = <String>[];

  LinkFinisher get finisher => container.read(discordLinkFinisherProvider);

  LinkStatus get status => container.read(discordLinkStatusProvider);
}

Future<_Rig> _rig(http.Response Function(http.Request) answer) async {
  final rig = _Rig(answer);
  addTearDown(rig.container.dispose);
  return rig;
}

void main() {
  group('parseLinkCode', () {
    test('a code read off the page loses its dashes, spaces and case', () {
      expect(parseLinkCode(' abcde-fghjk-lmnpq-rstuv-wxyz2 \n'), _code);
    });

    test('the whole link reads as its code', () {
      expect(parseLinkCode('slimm://discord-link?code=$_code'), _code);
    });

    test('nothing, or far too much, is no code', () {
      expect(parseLinkCode('  - '), isNull);
      expect(parseLinkCode('A' * 65), isNull);
    });
  });

  group('complete', () {
    test('posts the cleaned code and refreshes the linked accounts', () async {
      final rig = await _rig((request) {
        if (request.url.path == '/me/links') return _json(200, []);
        return _json(200, _linked);
      });
      rig.container.listen(myLinkedAccountsProvider, (_, _) {});
      await rig.container.read(myLinkedAccountsProvider.future);

      final failure = await rig.finisher.complete('abcde-fghjk-$_code');
      await rig.container.read(myLinkedAccountsProvider.future);

      expect(failure?.message, isNull);
      expect(jsonDecode(rig.bodies[1]), {
        'code': 'ABCDEFGHJKABCDEFGHJKLMNPQRSTUVWXYZ2',
      });
      expect(rig.paths.where((path) => path == '/me/links'), hasLength(2));
    });

    test(
      'a refused code says it may be expired or another account\'s',
      () async {
        final rig = await _rig((_) => _json(404, {'error': 'nope'}));
        final failure = await rig.finisher.complete(_code);
        expect(failure?.message, contains('may have expired'));
        expect(failure?.message, contains('another account'));
      },
    );

    test('a Discord account someone else holds says so', () async {
      final rig = await _rig(
        (_) => _json(409, {
          'error':
              'that Discord account is already linked to someone else here',
        }),
      );
      final failure = await rig.finisher.complete(_code);
      expect(failure?.message, contains('already linked to someone else here'));
    });

    test('an empty paste asks for the code without a request', () async {
      final rig = await _rig((_) => _json(200, _linked));
      final failure = await rig.finisher.complete('   ');
      expect(failure?.message, contains('Paste the code'));
      expect(rig.bodies, isEmpty);
    });

    test('a server that cannot be reached says nothing was changed', () async {
      final rig = await _rig((_) => throw http.ClientException('down'));
      final failure = await rig.finisher.complete(_code);
      expect(failure?.message, contains('could not be reached'));
    });
  });

  group('completeDelivered', () {
    test('reports through the status, and ends idle once linked', () async {
      final rig = await _rig((_) => _json(200, _linked));
      final seen = <LinkStatus>[];
      rig.container.listen(
        discordLinkStatusProvider,
        (_, next) => seen.add(next),
      );

      await rig.finisher.completeDelivered(_code);

      expect(seen.map((s) => s.runtimeType), [LinkFinishing, LinkIdle]);
    });

    test('a failure stays on the status until dismissed', () async {
      final rig = await _rig((_) => _json(404, {'error': 'nope'}));
      await rig.finisher.completeDelivered(_code);
      final status = rig.status;
      expect(status, isA<LinkFailed>());
      expect((status as LinkFailed).message, contains('did not work'));
    });

    test('the same code delivered twice is finished once', () async {
      final rig = await _rig((_) => _json(200, _linked));
      await rig.finisher.completeDelivered(_code);
      await rig.finisher.completeDelivered(_code.toLowerCase());
      expect(rig.bodies, hasLength(1));
    });

    test(
      'a code that failed for a transient reason can be delivered again',
      () async {
        var calls = 0;
        final rig = await _rig((_) {
          calls++;
          return calls == 1
              ? _json(500, {'error': 'boom'})
              : _json(200, _linked);
        });
        await rig.finisher.completeDelivered(_code);
        expect(rig.status, isA<LinkFailed>());

        await rig.finisher.completeDelivered(_code);

        expect(rig.bodies, hasLength(2));
        expect(rig.status, isA<LinkIdle>());
      },
    );

    test('a refused code is not retried when delivered again', () async {
      final rig = await _rig((_) => _json(404, {'error': 'nope'}));
      await rig.finisher.completeDelivered(_code);
      await rig.finisher.completeDelivered(_code);
      expect(rig.bodies, hasLength(1));
    });

    test(
      'a pasted code that links clears an earlier delivery failure',
      () async {
        var calls = 0;
        final rig = await _rig((_) {
          calls++;
          return calls == 1
              ? _json(404, {'error': 'nope'})
              : _json(200, _linked);
        });
        await rig.finisher.completeDelivered(_code);
        expect(rig.status, isA<LinkFailed>());

        expect(await rig.finisher.complete(_code), isNull);

        expect(rig.status, isA<LinkIdle>());
      },
    );
  });
}
