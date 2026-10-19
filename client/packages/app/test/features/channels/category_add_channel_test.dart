// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The `+` on a rail section header.
///
/// The owner asked for it directly: "a category should have a + aligned
/// right for creating channel". Aligned right is the load-bearing half -
/// `ChannelRow`'s kebab already carries a comment claiming the two glyphs
/// share a right edge, and that comment described something that did not
/// exist for as long as there was no glyph to share one with. This measures
/// it rather than trusting the comment.
///
/// It is also the only pointer-free way to create a channel in a chosen
/// section: the rail's blank-space menu is a right-click, which a finger
/// cannot perform.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ChannelCategoryRow _category() =>
    const ChannelCategoryRow(id: 'cat1', name: 'Lounge', position: 0);

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

void main() {
  testWidgets('a manager gets a + on the category header', (tester) async {
    await _pump(tester, canManage: true);

    expect(find.bySemanticsLabel('Create a channel in Lounge'), findsOneWidget);
  });

  testWidgets('somebody without MANAGE_CHANNELS gets no +', (tester) async {
    await _pump(tester, canManage: false);

    expect(find.bySemanticsLabel('Create a channel in Lounge'), findsNothing);
  });

  testWidgets('the + and a row kebab land on the same right edge', (
    tester,
  ) async {
    await _pump(tester, canManage: true);

    // The kebab is hover-revealed by opacity, so it is laid out and measurable without one.
    final add = tester.getRect(
      find.bySemanticsLabel('Create a channel in Lounge'),
    );
    final kebab = tester.getRect(find.bySemanticsLabel('Manage general'));

    expect(
      add.right,
      moreOrLessEquals(kebab.right, epsilon: 0.5),
      reason: 'ChannelRow\'s kebab comment claims this; it has to be true',
    );
  });
}
