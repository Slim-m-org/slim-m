// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two verbs on a category header's context menu.
///
/// The owner asked for a menu that renames or deletes, and for channel
/// management to stop being a maze: deleting a category used to be a menu,
/// then a sheet, then a danger zone, then a confirmation. Delete now reaches
/// the confirmation directly, and the test that matters is that the sheet is
/// not on the way - a green "it deleted" test would pass either way.
///
/// Both verbs are behind MANAGE_CHANNELS, which `ChannelCategorySections`
/// takes as `canManage`; a header rendered without it has no menu at all.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ChannelCategoryRow _category() =>
    const ChannelCategoryRow(id: 'cat1', name: 'Lounge', position: 0);

/// One channel in the category, so the section renders for a non-manager too:
/// an empty category is drawn only for somebody who could drop a channel into
/// it, so without this the no-permission case would have no header to press
/// and would pass for the wrong reason.
Channel _channel() => const Channel(
  id: 'c1',
  name: 'general',
  kind: 'text',
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: 'cat1',
);

Future<void> _pump(WidgetTester tester, {required bool canManage}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelCategorySections(
            channels: [_channel()],
            categories: [_category()],
            selectedId: null,
            canManage: canManage,
            onReorder: (_) {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the header's context menu the way a desktop right-click does.
Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.text('Lounge'), buttons: kSecondaryButton);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a manager is offered both verbs by name', (tester) async {
    await _pump(tester, canManage: true);
    await _openMenu(tester);

    expect(find.text('Rename category...'), findsOneWidget);
    expect(find.text('Delete category...'), findsOneWidget);
    // The old single entry that opened a sheet holding both.
    expect(find.text('Manage category...'), findsNothing);
  });

  testWidgets('delete reaches the confirmation without the sheet on the way', (
    tester,
  ) async {
    await _pump(tester, canManage: true);
    await _openMenu(tester);

    await tester.tap(find.text('Delete category...'));
    await tester.pumpAndSettle();

    // The confirmation, naming the category and promising its channels live.
    expect(find.textContaining('Delete "Lounge"?'), findsOneWidget);
    expect(find.textContaining('fall back to'), findsOneWidget);
    // The sheet's own heading: if this appears, the shortcut is not a shortcut.
    expect(find.text('Manage category'), findsNothing);
    // And the sheet's name field, which a rename needs and a delete does not.
    expect(find.byType(AppInput), findsNothing);
  });

  testWidgets('rename opens the sheet, which is where the field is', (
    tester,
  ) async {
    await _pump(tester, canManage: true);
    await _openMenu(tester);

    await tester.tap(find.text('Rename category...'));
    await tester.pumpAndSettle();

    expect(find.text('Manage category'), findsOneWidget);
    expect(find.byType(AppInput), findsOneWidget);
  });

  testWidgets('without MANAGE_CHANNELS the header has no menu', (tester) async {
    await _pump(tester, canManage: false);
    await _openMenu(tester);

    expect(find.text('Rename category...'), findsNothing);
    expect(find.text('Delete category...'), findsNothing);
  });
}
