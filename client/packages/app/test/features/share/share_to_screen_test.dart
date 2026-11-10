// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Share to": the page a share from the OS sheet lands on, from the
/// conversation list through to handing the share to the chosen composer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_drafts.dart';
import 'package:slimm_app/src/features/messages/providers/forward_targets.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/features/share/screens/share_to_screen.dart';
import 'package:slimm_app/src/features/share/widgets/share_destination_step.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_design_system/design_system.dart';

import '../accounts/account_host_harness.dart';
import '../accounts/account_switcher_support.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _photo = SharedFile(
  path: '/cache/1/a.jpg',
  name: 'a.jpg',
  length: 2048,
  mimeType: 'image/jpeg',
);

const _targets = [
  ForwardTarget(channelId: 'c-general', label: 'general', isDm: false),
  ForwardTarget(
    channelId: 'c-lounge',
    label: 'lounge',
    isDm: false,
    isVoice: true,
  ),
  ForwardTarget(
    channelId: 'c-bob',
    label: 'Bob',
    isDm: true,
    userId: 'bob',
    username: 'bobby',
  ),
];

/// Drafts held in memory; the real controller waits on a store that never opens in a widget test.
class _MemoryDrafts implements ChannelDraftsController {
  final _drafts = <String, String>{};

  @override
  Future<void> get restored async {}

  @override
  String draftFor(String channelId) => _drafts[channelId] ?? '';

  @override
  void save(String channelId, String text) => _drafts[channelId] = text;

  @override
  void clear(String channelId) => _drafts.remove(channelId);

  @override
  void dispose() {}
}

GoRouter _router() => GoRouter(
  initialLocation: Routes.share,
  routes: [
    GoRoute(path: Routes.share, builder: (_, _) => const ShareToScreen()),
    GoRoute(
      path: Routes.channels,
      builder: (_, _) => const Text('channels home'),
    ),
    GoRoute(
      path: Routes.channelPattern,
      builder: (_, state) => Text(
        'opened ${state.pathParameters['channelId']}'
        '${Routes.opensChat(state.uri) ? ' as chat' : ''}',
      ),
    ),
  ],
);

Widget _app(ProviderContainer container, GoRouter router) =>
    UncontrolledProviderScope(
      key: ObjectKey(container),
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    );

Future<ProviderContainer> _pumpShare(
  WidgetTester tester,
  IncomingShare share,
) async {
  tester.view.physicalSize = const Size(390, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      forwardTargetsProvider.overrideWith((ref, query) async => _targets),
      channelDraftsProvider.overrideWithValue(_MemoryDrafts()),
    ],
  );
  addTearDown(container.dispose);
  container.read(pendingShareProvider.notifier).state = PendingShare(share);
  await tester.pumpWidget(_app(container, _router()));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return container;
}

void main() {
  testWidgets('lists what is shared and every conversation it may go to', (
    tester,
  ) async {
    await _pumpShare(tester, const IncomingShare(files: [_photo, _photo]));
    expect(find.text('Share to'), findsOneWidget);
    expect(find.text('2 photos'), findsOneWidget);
    expect(find.text('general'), findsOneWidget);
    expect(find.text('lounge'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
  });

  testWidgets('searching narrows the list, by username as well as name', (
    tester,
  ) async {
    await _pumpShare(tester, const IncomingShare(files: [_photo]));

    await tester.enterText(find.byKey(ShareDestinationStep.searchKey), 'bobby');
    await tester.pump();

    expect(find.text('Bob'), findsOneWidget);
    expect(find.text('general'), findsNothing);
  });

  testWidgets('choosing a channel hands the files over and opens it', (
    tester,
  ) async {
    final container = await _pumpShare(
      tester,
      const IncomingShare(files: [_photo]),
    );

    await tester.tap(find.text('general'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final handoff = container.read(shareHandoffProvider);
    expect(handoff?.channelId, 'c-general');
    expect(handoff?.share.files.single.name, 'a.jpg');
    expect(container.read(pendingShareProvider), isNull);
    expect(find.text('opened c-general'), findsOneWidget);
  });

  testWidgets('a voice channel opens its chat rather than joining the call', (
    tester,
  ) async {
    await _pumpShare(tester, const IncomingShare(files: [_photo]));

    await tester.tap(find.text('lounge'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('opened c-lounge as chat'), findsOneWidget);
  });

  testWidgets('shared text becomes the draft, after what was already typed', (
    tester,
  ) async {
    final container = await _pumpShare(
      tester,
      const IncomingShare(text: 'https://example.com/page'),
    );
    container.read(channelDraftsProvider).save('c-general', 'look at this');

    await tester.tap(find.text('general'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(
      container.read(channelDraftsProvider).draftFor('c-general'),
      'look at this\nhttps://example.com/page',
    );
    expect(
      container.read(shareHandoffProvider),
      isNull,
      reason: 'text alone has no files for a composer to stage',
    );
  });

  testWidgets('going back drops the share instead of leaving it pending', (
    tester,
  ) async {
    final container = await _pumpShare(
      tester,
      const IncomingShare(files: [_photo]),
    );

    await tester.tap(find.bySemanticsLabel('Cancel sharing'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(pendingShareProvider), isNull);
    expect(find.text('channels home'), findsOneWidget);
  });

  testWidgets('a share nothing of which could be read says so', (tester) async {
    final container = await _pumpShare(
      tester,
      const IncomingShare(unreadable: 2),
    );

    expect(find.text(ShareToScreen.unreadableMessage), findsOneWidget);
    expect(find.text('general'), findsNothing);

    await tester.tap(find.text('Close'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(container.read(pendingShareProvider), isNull);
  });

  group('with several servers signed in', () {
    Future<AccountHarness> pumpTwoServers(WidgetTester tester) async {
      final h = await twoServers(tester, size: const Size(390, 800));
      final routers = <ProviderContainer, GoRouter>{};
      final active = h.host.active!.container;
      active.read(pendingShareProvider.notifier).state = const PendingShare(
        IncomingShare(files: [_photo]),
      );
      await tester.pumpWidget(
        ListenableBuilder(
          listenable: h.host,
          builder: (context, _) {
            final container = h.host.active!.container;
            return _app(container, routers.putIfAbsent(container, _router));
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return h;
    }

    testWidgets('it asks which server before listing conversations', (
      tester,
    ) async {
      await pumpTwoServers(tester);

      expect(find.text('SERVERS'), findsOneWidget);
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(find.text('general'), findsNothing);
    });

    testWidgets('choosing the server on screen moves on to its conversations', (
      tester,
    ) async {
      final h = await pumpTwoServers(tester);

      await tester.tap(find.text('First'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('SERVERS'), findsNothing);
      expect(
        h.host.active!.container.read(pendingShareProvider)?.serverChosen,
        isTrue,
      );
    });

    testWidgets('choosing another server brings it forward with the share', (
      tester,
    ) async {
      final h = await pumpTwoServers(tester);
      final first = h.host.active!;

      await tester.tap(find.text('Second'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final second = h.host.runtimeFor('https://second.example')!;
      expect(h.host.active, second);
      expect(second.container.read(pendingShareProvider)?.serverChosen, isTrue);
      expect(first.container.read(pendingShareProvider), isNull);
    });
  });
}
