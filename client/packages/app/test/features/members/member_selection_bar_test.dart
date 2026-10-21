// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bar at the foot of the member pane, and the requests its two verbs
/// actually send.
///
/// The requests are the part worth pinning. A bulk remove that quietly looped
/// the single-member endpoint would look identical on screen while losing
/// every property the bulk route exists for: one transaction, so a batch
/// naming somebody above the caller removes nobody, and one audit row per
/// member rather than per act.
///
/// The permission split is the other half. KICK_MEMBERS and BAN_MEMBERS are
/// held separately, so a moderator with only one of them must be offered only
/// that verb - and offered it as an absent control rather than a dead one,
/// since no amount of selecting would make the missing bit appear.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_selection.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_selection_bar.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final List<String> requests = [];
final List<Object?> bodies = [];

api.SlimmApi _api(api.SessionStore session) => testApi((request) async {
  requests.add('${request.method} ${request.url.path}');
  if (request.body.isNotEmpty) bodies.add(jsonDecode(request.body));
  return http.Response('', 204);
}, session: session);

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  bool canTimeOut = true,
  bool canRemove = true,
  void Function(Duration)? onTimeOut,
  Future<void> Function()? onRemove,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final client = _api(ref.watch(sessionProvider));
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: MemberSelectionBar(
            canTimeOut: canTimeOut,
            canRemove: canRemove,
            onTimeOut: onTimeOut ?? (_) {},
            onRemove: onRemove ?? () async {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// The container's api client, for a callback that needs to send something.
api.SlimmApi _apiOf(WidgetTester tester) {
  final element = tester.element(find.byType(MemberSelectionBar));
  return ProviderScope.containerOf(element).read(apiProvider);
}

void main() {
  setUp(() {
    requests.clear();
    bodies.clear();
  });

  testWidgets('the count is what the verbs are about to act on', (
    tester,
  ) async {
    final container = await _pump(tester);
    final selection = container.read(memberSelectionProvider.notifier);
    selection.enter();
    selection.toggle('u1');
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);

    selection.toggle('u2');
    await tester.pumpAndSettle();
    expect(find.text('2 selected'), findsOneWidget);
  });

  testWidgets('no verb is offered until somebody is selected', (tester) async {
    final container = await _pump(tester);
    container.read(memberSelectionProvider.notifier).enter();
    await tester.pumpAndSettle();

    expect(find.text('Remove'), findsNothing);
    expect(find.text('Cancel'), findsOneWidget);

    container.read(memberSelectionProvider.notifier).toggle('u1');
    await tester.pumpAndSettle();
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('a moderator holding only KICK_MEMBERS is offered no remove', (
    tester,
  ) async {
    final container = await _pump(tester, canRemove: false);
    final selection = container.read(memberSelectionProvider.notifier)..enter();
    selection.toggle('u1');
    await tester.pumpAndSettle();

    expect(find.text('Remove'), findsNothing);
    // The timeout chips are still there, so the bar is not simply empty.
    expect(find.text('5m'), findsOneWidget);
  });

  testWidgets('a moderator holding only BAN_MEMBERS is offered no timeout', (
    tester,
  ) async {
    final container = await _pump(tester, canTimeOut: false);
    final selection = container.read(memberSelectionProvider.notifier)..enter();
    selection.toggle('u1');
    await tester.pumpAndSettle();

    expect(find.text('5m'), findsNothing);
    expect(find.text('Remove'), findsOneWidget);
  });

  testWidgets('cancel leaves the mode', (tester) async {
    final container = await _pump(tester);
    container.read(memberSelectionProvider.notifier).enter();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(container.read(memberSelectionProvider).active, isFalse);
  });

  testWidgets('a full selection says why it stopped growing', (tester) async {
    final container = await _pump(tester);
    final selection = container.read(memberSelectionProvider.notifier)..enter();
    for (var i = 0; i < maxBulkMemberIds; i++) {
      selection.toggle('u$i');
    }
    await tester.pumpAndSettle();
    expect(
      find.text('$maxBulkMemberIds selected, the most at once'),
      findsOneWidget,
    );
  });

  testWidgets('the Remove button is what sends one bulk request', (
    tester,
  ) async {
    var removes = 0;
    final container = await _pump(
      tester,
      onRemove: () async {
        removes++;
        await _apiOf(tester).bulkRemoveMembers(userIds: ['u1', 'u2', 'u3']);
      },
    );
    final selection = container.read(memberSelectionProvider.notifier)..enter();
    selection.toggle('u1');
    selection.toggle('u2');
    selection.toggle('u3');
    await tester.pumpAndSettle();

    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(removes, 1);
    expect(requests, [
      'POST /members/bulk-removal',
    ], reason: 'one request for the batch, never one per member');
    expect((bodies.single! as Map)['user_ids'], hasLength(3));
  });

  testWidgets('tapping a chip reports that chip\'s duration', (tester) async {
    Duration? chosen;
    final container = await _pump(tester, onTimeOut: (d) => chosen = d);
    final selection = container.read(memberSelectionProvider.notifier)..enter();
    selection.toggle('u1');
    await tester.pumpAndSettle();

    await tester.tap(find.text('1h'));
    await tester.pumpAndSettle();
    expect(chosen, const Duration(hours: 1));
  });

  testWidgets('the timeout request carries the seconds the chip named', (
    tester,
  ) async {
    final container = await _pump(tester);
    container.read(memberSelectionProvider.notifier).enter();
    await tester.pumpAndSettle();

    await container
        .read(apiProvider)
        .bulkTimeoutMembers(
          userIds: ['u1'],
          duration: const Duration(hours: 1),
        );

    expect(requests, ['POST /members/bulk-timeout']);
    expect((bodies.single! as Map)['duration_seconds'], 3600);
  });

  group('at phone width', () {
    Future<ProviderContainer> phone(
      WidgetTester tester, {
      void Function(Duration)? onTimeOut,
      Future<void> Function()? onRemove,
    }) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = await _pump(
        tester,
        onTimeOut: onTimeOut,
        onRemove: onRemove,
      );
      container.read(memberSelectionProvider.notifier)
        ..enter()
        ..toggle('u1');
      await tester.pumpAndSettle();
      return container;
    }

    testWidgets('the bar is one short strip, with no chips inside it', (
      tester,
    ) async {
      await phone(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('5m'), findsNothing);
      expect(find.text('Remove'), findsNothing);
      expect(
        tester.getSize(find.byType(MemberSelectionBar)).height,
        lessThan(110),
        reason: 'a tall bar is what half-covered the roster',
      );
    });

    testWidgets('the durations share one row that fits 390px', (tester) async {
      Duration? chosen;
      await phone(tester, onTimeOut: (d) => chosen = d);
      await tester.tap(find.text('Moderate'));
      await tester.pumpAndSettle();

      final tops = {
        for (final l in ['5m', '1h', '24h', '7d'])
          l: tester.getTopLeft(find.text(l)).dy,
      };
      expect(tops.values.toSet(), hasLength(1), reason: 'wrapped: $tops');
      expect(tester.getTopRight(find.text('7d')).dx, lessThan(390));
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('24h'));
      await tester.pumpAndSettle();
      expect(chosen, const Duration(hours: 24));
      expect(
        find.text('Time out for...'),
        findsNothing,
        reason: 'sheet closes',
      );
    });

    testWidgets('Remove sits apart from the durations and fires once', (
      tester,
    ) async {
      var removes = 0;
      await phone(tester, onRemove: () async => removes++);
      await tester.tap(find.text('Moderate'));
      await tester.pumpAndSettle();

      final gap =
          tester.getTopLeft(find.text('Remove')).dy -
          tester.getBottomLeft(find.text('24h')).dy;
      expect(gap, greaterThan(32), reason: 'divider plus padding between');

      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(removes, 1);
    });
  });
}
