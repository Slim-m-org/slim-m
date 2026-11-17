// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Previewing a role swaps the shell for that role's rail under a read-only banner; opening a
/// channel shows what the role can do there instead of messages, and Exit restores the real view.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/role_preview/providers/role_preview_controller.dart';
import 'package:slimm_app/src/features/role_preview/widgets/role_preview_banner.dart';

import '../../support/async_wait.dart';
import 'role_preview_fixture.dart';

void main() {
  testWidgets(
    'entering shows the banner and the role rail in place of the real one',
    (tester) async {
      final (:container, :db) = await pumpPreviewShell(tester);
      expect(find.byKey(ChannelRail.surfaceKey), findsOneWidget);

      await enterPreview(tester, container);
      expect(container.read(rolePreviewProvider)?.preview.hasValue, isTrue);

      expect(
        find.text('Viewing as cs - read-only', findRichText: true),
        findsOneWidget,
      );
      expect(
        find.textContaining('read-only', findRichText: true),
        findsOneWidget,
      );
      expect(find.byKey(ChannelRail.surfaceKey), findsNothing);
      expect(find.text('conversation'), findsNothing);
      for (final name in ['general', 'gamers', 'cs2', 'cs-chat']) {
        expect(find.text(name), findsOneWidget, reason: name);
      }
      expect(find.byWidgetPredicate((w) => w is EditableText), findsNothing);
      await teardownPreviewShell(tester, container, db);
    },
  );

  testWidgets(
    'opening a channel shows what the role can do there, not messages',
    (tester) async {
      final (:container, :db) = await pumpPreviewShell(tester);
      await enterPreview(tester, container);
      expect(container.read(rolePreviewProvider)?.preview.hasValue, isTrue);

      await tester.tap(find.text('cs-chat'));
      await pumpFrames(tester);

      expect(find.text('What cs can do here'), findsOneWidget);
      expect(find.text('View channels'), findsOneWidget);
      expect(find.text('Send messages'), findsOneWidget);
      expect(find.text('Yes'), findsNWidgets(2));
      expect(find.text('No'), findsWidgets);
      expect(find.byWidgetPredicate((w) => w is EditableText), findsNothing);
      await teardownPreviewShell(tester, container, db);
    },
  );

  testWidgets('the palette shortcut opens nothing while previewing', (
    tester,
  ) async {
    final (:container, :db) = await pumpPreviewShell(tester);
    await enterPreview(tester, container);
    expect(container.read(rolePreviewProvider)?.preview.hasValue, isTrue);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await pumpFrames(tester);

    expect(find.byWidgetPredicate((w) => w is EditableText), findsNothing);
    expect(find.text('conversation'), findsNothing);
    await teardownPreviewShell(tester, container, db);
  });

  testWidgets(
    'exit restores the real rail and writes nothing to the local store',
    (tester) async {
      final (:container, :db) = await pumpPreviewShell(tester);
      await enterPreview(tester, container);
      expect(container.read(rolePreviewProvider)?.preview.hasValue, isTrue);

      await tester.tap(find.byKey(RolePreviewBanner.exitKey));
      await pumpFrames(tester);

      expect(container.read(rolePreviewProvider), isNull);
      expect(find.byKey(ChannelRail.surfaceKey), findsOneWidget);
      expect(find.text('conversation'), findsOneWidget);
      expect(
        find.text('Viewing as cs - read-only', findRichText: true),
        findsNothing,
      );
      final stored = await tester.runAsync(
        () async => (
          await db.select(db.channelCategories).get(),
          await db.select(db.channels).get(),
        ),
      );
      expect(stored!.$1, isEmpty);
      expect(stored.$2, isEmpty);
      await teardownPreviewShell(tester, container, db);
    },
  );
}
