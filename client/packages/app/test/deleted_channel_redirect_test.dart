// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A channel deleted while it is on screen (a closed ticket, most often)
/// leaves for the conversation before it with a short notice, instead of
/// sitting on "Could not open this channel.".
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/last_text_channel.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';

GoRouter _router(WidgetTester tester) =>
    GoRouter.of(tester.element(find.byType(Navigator).first));

String _location(WidgetTester tester) =>
    _router(tester).routerDelegate.currentConfiguration.last.matchedLocation;

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<({ProviderContainer container, SlimmDatabase db})> _open(
  WidgetTester tester,
  double width,
) async {
  final quiet = quietClient();
  final s = setup(
    httpClient: MockClient((request) => quiet.get(request.url)),
    signedIn: true,
    extraOverrides: [initialSyncCompleteProvider.overrideWith((ref) => true)],
  );
  await MessageStore(s.db).upsertChannels([
    const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    const api.Channel(
      id: 'c2',
      name: 'ticket-0004',
      kind: 'text',
      createdAt: 0,
    ),
  ]);
  await pumpAtWidth(tester, s.container, width, location: '/channels/c1');
  await _settle(tester);
  _router(tester).go('/channels/c2');
  await _settle(tester);
  return s;
}

Future<void> _delete(ProviderContainer container, SlimmDatabase db) async {
  final deleted = container.read(deletedChannelsProvider.notifier);
  deleted.state = {...deleted.state, 'c2': 'ticket-0004'};
  await MessageStore(db).removeChannel('c2');
}

void main() {
  for (final width in [1400.0, 390.0]) {
    testWidgets('at $width, a deleted open channel goes back with a notice', (
      tester,
    ) async {
      final s = await _open(tester, width);
      expect(_location(tester), '/channels/c2');

      await _delete(s.container, s.db);
      await _settle(tester);

      expect(_location(tester), '/channels/c1');
      expect(find.text('Could not open this channel.'), findsNothing);
      expect(
        s.container.read(toastsProvider).map((t) => t.message),
        contains('#ticket-0004 was deleted'),
      );
      await teardown(tester, s.container, s.db);
    });
  }

  testWidgets('a channel that was never seen still reads as not found', (
    tester,
  ) async {
    final s = await _open(tester, 1400);
    _router(tester).go('/channels/nowhere');
    await _settle(tester);

    expect(_location(tester), '/channels/nowhere');
    expect(s.container.read(toastsProvider), isEmpty);
    await teardown(tester, s.container, s.db);
  });

  test('the fallback is never the channel that went away', () {
    expect(fallbackChannel(last: 'c2', previous: 'c1', gone: 'c2'), 'c1');
    expect(fallbackChannel(last: 'c1', previous: 'c0', gone: 'c2'), 'c1');
    expect(fallbackChannel(last: 'c2', previous: 'c2', gone: 'c2'), isNull);
    expect(fallbackChannel(last: null, previous: null, gone: 'c2'), isNull);
  });
}
