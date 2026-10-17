// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas header used to say only "Canvas", with no way to tell which
/// channel's canvas was open - unlike the voice call header beside it. See
/// `canvas_bar.dart`'s own doc for why the identity-only header stays that
/// way and only gains the channel's name.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart'
    show canvasOpenProvider;
import 'package:slimm_data/data.dart';

import 'home_shell_harness.dart';

void main() {
  testWidgets('names a real voice channel alongside "Canvas"', (tester) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'voice', createdAt: 0),
    ]);
    s.container.read(canvasOpenProvider.notifier).state = 'c1';

    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

    expect(find.text('general, Canvas'), findsOneWidget);
    expect(find.text('Canvas'), findsNothing);

    await teardown(tester, s.container, s.db);
  });

  testWidgets('names a DM peer alongside "Canvas"', (tester) async {
    final s = setup(httpClient: quietClient(), signedIn: true);
    await MessageStore(s.db).upsertChannels([
      const api.Channel(
        id: 'c1',
        name: 'Alice',
        kind: 'dm',
        createdAt: 0,
        dmParticipantId: 'alice',
      ),
    ]);
    s.container.read(canvasOpenProvider.notifier).state = 'c1';

    await pumpAtWidth(tester, s.container, 1400, location: '/channels/c1');

    expect(find.text('Alice, Canvas'), findsOneWidget);

    await teardown(tester, s.container, s.db);
  });

  testWidgets(
    'falls back to plain "Canvas" while the channel row has not loaded yet',
    (tester) async {
      final s = setup(httpClient: quietClient(), signedIn: true);
      s.container.read(canvasOpenProvider.notifier).state = 'unknown-channel';

      await pumpAtWidth(
        tester,
        s.container,
        1400,
        location: '/channels/unknown-channel',
      );

      expect(find.text('Canvas'), findsOneWidget);

      await teardown(tester, s.container, s.db);
    },
  );
}
