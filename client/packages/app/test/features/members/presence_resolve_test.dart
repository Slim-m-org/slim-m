// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The single mapping from what the client knows about a person to the state
/// drawn, for every state including "not known yet".
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/features/members/providers/presence_view.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/call_header_fixture.dart' show FakePresence;

void main() {
  group('someone else', () {
    test('each reported state maps to its own state', () {
      expect(
        resolvePresence(reported: api.PresenceState.online, isSelf: false),
        AppPresence.online,
      );
      expect(
        resolvePresence(reported: api.PresenceState.away, isSelf: false),
        AppPresence.away,
      );
      expect(
        resolvePresence(reported: api.PresenceState.dnd, isSelf: false),
        AppPresence.dnd,
      );
      expect(
        resolvePresence(reported: api.PresenceState.offline, isSelf: false),
        AppPresence.offline,
      );
    });

    test('not reported yet is unknown, never offline', () {
      expect(
        resolvePresence(reported: null, isSelf: false),
        AppPresence.unknown,
      );
    });

    test('a hidden person cannot be told from an offline one', () {
      expect(
        resolvePresence(reported: api.PresenceState.offline, isSelf: false),
        isNot(AppPresence.hidden),
      );
    });

    test('a choice belongs to the caller and never changes anyone else', () {
      expect(
        resolvePresence(
          reported: api.PresenceState.online,
          isSelf: false,
          chosen: api.PresenceVisibility.hidden,
        ),
        AppPresence.online,
      );
    });
  });

  group('the signed-in user', () {
    test('is never unknown to themself', () {
      expect(resolvePresence(reported: null, isSelf: true), AppPresence.online);
    });

    test('reads the server report when no choice was made', () {
      expect(
        resolvePresence(reported: api.PresenceState.away, isSelf: true),
        AppPresence.away,
      );
      expect(
        resolvePresence(reported: api.PresenceState.dnd, isSelf: true),
        AppPresence.dnd,
      );
    });

    test('a choice made this session wins over the report', () {
      expect(
        resolvePresence(
          reported: api.PresenceState.online,
          isSelf: true,
          chosen: api.PresenceVisibility.hidden,
        ),
        AppPresence.hidden,
      );
      expect(
        resolvePresence(
          reported: null,
          isSelf: true,
          chosen: api.PresenceVisibility.dnd,
        ),
        AppPresence.dnd,
      );
      expect(
        resolvePresence(
          reported: api.PresenceState.away,
          isSelf: true,
          chosen: api.PresenceVisibility.online,
        ),
        AppPresence.online,
      );
    });
  });

  group('words', () {
    test('every known state has one word and unknown has none', () {
      expect(
        {for (final s in AppPresence.values) s: s.word},
        {
          AppPresence.online: 'online',
          AppPresence.away: 'away',
          AppPresence.dnd: 'do not disturb',
          AppPresence.offline: 'offline',
          AppPresence.hidden: 'appearing offline',
          AppPresence.unknown: null,
        },
      );
    });
  });

  group('presenceForProvider', () {
    const tokens = api.TokenPair(
      userId: 'me',
      accessToken: 'a',
      refreshToken: 'r',
      accessExpiresAt: 0,
    );

    ProviderContainer container(Map<String, api.PresenceState> seed) =>
        ProviderContainer(
          overrides: [
            sessionProvider.overrideWithValue(api.SessionStore(tokens: tokens)),
            presenceControllerProvider.overrideWith(
              (ref) => FakePresence(ref, seed),
            ),
          ],
        );

    test('one rule answers for the caller and for everybody else', () {
      final c = container({'other': api.PresenceState.away});
      addTearDown(c.dispose);
      expect(c.read(presenceForProvider('me')), AppPresence.online);
      expect(c.read(presenceForProvider('other')), AppPresence.away);
      expect(c.read(presenceForProvider('stranger')), AppPresence.unknown);
    });

    test('a live report and a local choice both reach it', () async {
      final c = container({});
      addTearDown(c.dispose);
      final seen = <AppPresence>[];
      c.listen(presenceForProvider('me'), (_, next) => seen.add(next));
      c.read(presenceControllerProvider.notifier).state = {
        'me': api.PresenceState.dnd,
      };
      await Future<void>.delayed(Duration.zero);
      c.read(presenceVisibilityDisplayProvider.notifier).state =
          api.PresenceVisibility.hidden;
      await Future<void>.delayed(Duration.zero);
      expect(seen, [AppPresence.dnd, AppPresence.hidden]);
    });
  });
}
