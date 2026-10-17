// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one affordance that reaches a DM's call.
///
/// `DmCallButton` is self-gated on the channel's own kind rather than a
/// caller-supplied flag, so what matters is that it appears for an ordinary
/// DM and nowhere else, and that a tap toggles `dmCallOpenProvider` - the
/// same reachability shape `canvas_pane_test.dart` already pins for the
/// canvas's own header affordance.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/dms.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/dm_call_button.dart';
import 'package:slimm_app/src/screens/dm_call_pane.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

/// Pumps [DmCallButton] for [channel] with its row already in the local
/// store. The `StreamBuilder` this button watches defers its drift cleanup
/// onto a timer the test clock only advances on a later pump, so a caller
/// must unmount via [_teardown] before disposing rather than disposing
/// straight away.
Future<({ProviderContainer container, SlimmDatabase db})> _pumpButton(
  WidgetTester tester,
  api.Channel channel,
) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  final store = MessageStore(db);
  await store.upsertChannels([channel]);

  final container = ProviderContainer(
    overrides: [storeProvider.overrideWith((ref) async => store)],
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(body: DmCallButton(channelId: channel.id)),
      ),
    ),
  );
  // Bounded, not pumpAndSettle: see channel_screen_test.dart's own note.
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return (container: container, db: db);
}

/// Unmounts before disposing, and pumps past the drift cleanup timer the
/// unmount schedules - see `home_shell_test.dart`'s identically-shaped
/// `_teardown` for why the order matters.
Future<void> _teardown(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  // Dispose before the pump: the button reads its channel through an autoDispose provider that defers cancelling its drift subscription to disposal, so the pump has to land after it to advance drift's cleanup timer.
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

void main() {
  testWidgets('an ordinary DM shows the call button', (tester) async {
    final setup = await _pumpButton(
      tester,
      api.Channel(id: 'dm-1', name: 'Alice', kind: 'dm', createdAt: 0),
    );

    expect(find.bySemanticsLabel('Call'), findsOneWidget);
    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('a text channel shows no call button', (tester) async {
    final setup = await _pumpButton(
      tester,
      api.Channel(id: 'c-1', name: 'general', kind: 'text', createdAt: 0),
    );

    expect(find.bySemanticsLabel('Call'), findsNothing);
    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('a voice channel shows no call button', (tester) async {
    final setup = await _pumpButton(
      tester,
      api.Channel(id: 'c-1', name: 'general', kind: 'voice', createdAt: 0),
    );

    expect(find.bySemanticsLabel('Call'), findsNothing);
    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('a personal space shows no call button', (tester) async {
    final setup = await _pumpButton(
      tester,
      api.Channel(
        id: 'dm-1',
        name: personalSpaceName,
        kind: 'dm',
        createdAt: 0,
        isPersonalSpace: true,
      ),
    );

    expect(
      find.bySemanticsLabel('Call'),
      findsNothing,
      reason: 'calling yourself is not a call',
    );
    await _teardown(tester, setup.container, setup.db);
  });

  testWidgets('tapping the button opens, and closes, the DM call pane', (
    tester,
  ) async {
    final setup = await _pumpButton(
      tester,
      api.Channel(id: 'dm-1', name: 'Alice', kind: 'dm', createdAt: 0),
    );

    expect(setup.container.read(dmCallOpenProvider), isNull);
    await tester.tap(find.bySemanticsLabel('Call'));
    await tester.pump();
    expect(setup.container.read(dmCallOpenProvider), 'dm-1');

    await tester.tap(find.bySemanticsLabel('Call'));
    await tester.pump();
    expect(setup.container.read(dmCallOpenProvider), isNull);

    await _teardown(tester, setup.container, setup.db);
  });
}
