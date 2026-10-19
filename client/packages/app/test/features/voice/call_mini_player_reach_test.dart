// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the mini-player stays clear of when the pane under it changes shape,
/// and that the keyboard reaches its one primary action.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/widgets/focusable_video_press.dart';

import '../../ui_snapshot_support.dart' show loadRealFonts;
import 'call_mini_player_harness.dart';

void main() {
  setUpAll(loadRealFonts);

  final player = find.byKey(miniPlayerKey);

  for (final (name, size) in [('wide', desktopSize), ('phone', phoneSize)]) {
    testWidgets('every corner clears a composer grown by a long draft, $name', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: size,
      );
      await tester.enterText(
        find.descendant(
          of: find.byType(Composer),
          matching: find.byType(EditableText),
        ),
        List.generate(6, (i) => 'line $i').join('\n'),
      );
      await settleMini(tester);
      final composer = tester.getRect(find.byType(Composer));
      expect(composer.height, greaterThan(miniPlayerComposerReserve - 12));
      for (final corner in MiniPlayerCorner.values) {
        ctx.container.read(miniPlayerCornerProvider.notifier).state = corner;
        await settleMini(tester);
        expect(
          tester.getRect(player).overlaps(composer),
          isFalse,
          reason: '$corner overlaps the grown composer $composer',
        );
      }
      await ctx.done();
    });
  }

  testWidgets('Tab reaches the card and Enter returns to the call', (
    tester,
  ) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall([remoteShare]),
      size: desktopSize,
    );
    var tabs = 0;
    while (!_onTheCard() && tabs < 60) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      tabs++;
    }
    expect(_onTheCard(), isTrue, reason: 'not reached in $tabs tabs');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settleMini(tester);
    expect(
      ctx.router.routeInformationProvider.value.uri.path,
      '/channels/c-main',
    );
    await ctx.done();
  });
}

bool _onTheCard() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<FocusableVideoPress>() !=
    null;
