// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reproduces backlog #108/#110: "Channels format weird, colors change [...]
/// mentions also get unhighlighted when the server was offline."
///
/// `rail_offline_shape_test.dart` and `mention_highlight_offline_test.dart`
/// already pin the two provider-level fixes ([effectiveMeProvider] and
/// [knownUsernamesFrom]) that this bug was closed with. This file drives the
/// same failure through a real dropped HTTP connection instead of a provider
/// override swap, rendering the actual production widgets
/// ([ChannelCategorySections], [MessageBody]) so the owner's ask ("a test so
/// you can see what I'm talking about") is something watchable, not just
/// readable.
///
/// The rail needs one more step than a bare `AsyncError` keeping its
/// previous value: [effectiveMeProvider] is not `autoDispose`, so once read
/// once it permanently outlives whatever widget asked - which is what stops
/// `meProvider` itself (which is `autoDispose`) tearing down and losing its
/// answer when the rail unmounts and remounts, the shape a phone's compact
/// layout takes swapping the rail for an open channel. The first two tests
/// unmount and remount across the drop to exercise exactly that; the second
/// names why, reading `meProvider` straight - the shape `channel_rail.dart`
/// used before #657.
///
/// The one thing *supposed* to change when the connection drops is
/// [SpaceConnectionDot]; the last test pins that as the only difference.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/screens/channel_screen.dart';
import 'package:slimm_app/src/widgets/space_connection_dot.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_app/src/features/messages/widgets/message_text.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _category = ChannelCategoryRow(
  id: 'announcements',
  name: 'Announcements',
  position: 0,
);

/// Stands in for the real [SyncController], which opens a websocket from its
/// own constructor as soon as the session is signed in; [start] is
/// overridden so this stays off the network, and [goOffline] then flips the
/// state the same way a real dropped socket does.
class _ToggleSyncController extends SyncController {
  _ToggleSyncController(super.ref) {
    state = SyncStatus.live;
  }

  @override
  Future<void> start() async {}

  void goOffline() => state = SyncStatus.offline;
}

/// A container wired like the app's, whose `/me` and `/members` answers flip
/// from a resolved manager profile and a one-member roster to a real
/// connection failure - the same kind of error a live app hits when the
/// network actually drops, rather than a 404 or a decode error.
({ProviderContainer container, void Function() disconnect}) _setup() {
  var connected = true;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith(_ToggleSyncController.new),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (!connected) {
              throw http.ClientException('connection refused');
            }
            if (request.url.path == '/me') {
              return http.Response(
                '{"id":"self","username":"self","display_name":"Self",'
                '"created_at":0,"permissions":${Perm.manageChannels}}',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/members') {
              return http.Response(
                '[{"id":"ada","username":"ada","display_name":"Ada",'
                '"created_at":0}]',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              '{}',
              404,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  return (
    container: container,
    disconnect: () {
      connected = false;
      container.invalidate(meProvider);
      container.invalidate(membersProvider);
    },
  );
}

/// Mirrors `channel_rail.dart`'s own `canManage` computation (lines 84-86,
/// 190-197): an empty category renders only for a manager, so this is the
/// exact real-world path the "channels format weird" bug broke.
///
/// [readMe] is swapped between the shipped read ([_readEffectiveMe]) and the
/// pre-fix one ([_readMeDirect]), which the second test below uses to show
/// why the shipped one has to exist; both are top-level so they tear off as
/// compile-time constants and this widget can stay `const`.
class _RailCategory extends ConsumerWidget {
  const _RailCategory(this.readMe);

  final api.Me? Function(WidgetRef ref) readMe;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = readMe(ref);
    final canManage =
        me != null && me.permissions.hasPermission(Perm.manageChannels);
    return ChannelCategorySections(
      channels: const [],
      categories: const [_category],
      selectedId: null,
      canManage: canManage,
      onReorder: (_) {},
    );
  }
}

api.Me? _readEffectiveMe(WidgetRef ref) => ref.watch(effectiveMeProvider);

/// The pre-fix shape `channel_rail.dart` used before #657: [meProvider]
/// itself, `autoDispose`, read with no permanent watcher keeping it alive.
api.Me? _readMeDirect(WidgetRef ref) => ref.watch(meProvider).valueOrNull;

/// Mirrors `channel_screen.dart`'s own transcript wiring (line 258): the same
/// [knownUsernamesFrom] call feeding the same [MessageBody] a real message
/// row renders.
class _MentionUnderTest extends ConsumerWidget {
  const _MentionUnderTest();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final knownUsernames = knownUsernamesFrom(ref.watch(membersProvider));
    return MessageBody(
      content: '@ada can you take a look',
      knownUsernames: knownUsernames,
    );
  }
}

Widget _harness(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    );

void main() {
  testWidgets('a rail remounted after a drop keeps the empty category visible', (
    tester,
  ) async {
    final setup = _setup();
    addTearDown(setup.container.dispose);

    await tester.pumpWidget(
      _harness(setup.container, const _RailCategory(_readEffectiveMe)),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Announcements'),
      findsOneWidget,
      reason: 'a manager sees every category, empty or not, while live',
    );

    // The compact layout unmounts the whole rail for an open channel; see this file's own doc comment for why that matters here.
    await tester.pumpWidget(_harness(setup.container, const SizedBox()));
    await tester.pumpAndSettle();

    setup.disconnect();
    await tester.pumpWidget(
      _harness(setup.container, const _RailCategory(_readEffectiveMe)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Announcements'),
      findsOneWidget,
      reason:
          'a failed /me refetch on remount is not evidence this member '
          'lost manage permission - losing the category header here is '
          'backlog #108, "channels format weird, colors change"',
    );
  });

  testWidgets('reading meProvider directly instead is what the fix replaced', (
    tester,
  ) async {
    final setup = _setup();
    addTearDown(setup.container.dispose);

    await tester.pumpWidget(
      _harness(setup.container, const _RailCategory(_readMeDirect)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Announcements'), findsOneWidget);

    await tester.pumpWidget(_harness(setup.container, const SizedBox()));
    await tester.pumpAndSettle();

    setup.disconnect();
    await tester.pumpWidget(
      _harness(setup.container, const _RailCategory(_readMeDirect)),
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Announcements'),
      findsNothing,
      reason:
          'kept here so the why survives: with nothing permanent watching '
          'it, meProvider genuinely disposes on unmount and comes back '
          'with no previous value to fall back on, which is the actual '
          'shape backlog #108 broke in',
    );
  });

  testWidgets(
    'a dropped connection keeps an already-known mention highlighted',
    (tester) async {
      final setup = _setup();
      addTearDown(setup.container.dispose);

      await tester.pumpWidget(
        _harness(setup.container, const _MentionUnderTest()),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('@ada'),
        findsOneWidget,
        reason:
            'rendered as its own Text widget only inside the chip, '
            'never inside the plain-text fallback span',
      );

      setup.disconnect();
      await tester.pumpAndSettle();

      expect(
        find.text('@ada'),
        findsOneWidget,
        reason:
            'a failed /members refetch is not evidence the deployment has no '
            'members - unhighlighting this mention here is backlog #110, '
            '"mentions also get unhighlighted when the server was offline"',
      );
    },
  );

  testWidgets('the connection dot is the only thing allowed to change here', (
    tester,
  ) async {
    final setup = _setup();
    addTearDown(setup.container.dispose);
    final sync =
        setup.container.read(syncControllerProvider.notifier)
            as _ToggleSyncController;

    await tester.pumpWidget(
      _harness(
        setup.container,
        SingleChildScrollView(
          child: Column(
            children: [
              Consumer(
                builder: (context, ref, _) => SpaceConnectionDot(
                  status: ref.watch(syncControllerProvider),
                ),
              ),
              const _RailCategory(_readEffectiveMe),
              const _MentionUnderTest(),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byTooltip('Connected to the server'), findsOneWidget);

    setup.disconnect();
    sync.goOffline();
    await tester.pumpAndSettle();

    expect(
      find.byTooltip('Offline, retrying'),
      findsOneWidget,
      reason: 'the dot honestly reporting the drop is correct, not a bug',
    );
    expect(find.text('Announcements'), findsOneWidget);
    expect(find.text('@ada'), findsOneWidget);
  });
}
