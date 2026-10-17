// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A line break grows the composer over a beat instead of relayouting in one
/// frame: the action bar rides an [AnimatedSize], so the mid-flight height
/// sits strictly between the one-line and two-line heights. Reverting the
/// wrapper to the bare container fails the mid-flight assertion here.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/composer_action_bar.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('a new line grows the composer over a beat', (tester) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final focus = FocusNode();
    addTearDown(focus.dispose);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ComposerActionBar(
                touch: false,
                controller: controller,
                focusNode: focus,
                channelId: 'c1',
                channelName: 'general',
                hasText: false,
                canSend: false,
                onSend: () async {},
                onTyping: (_) {},
                onOpenActions: () {},
                onPickFile: () {},
                onSendPressed: () {},
                onInsertCode: () {},
                onPickEmoji: () {},
                gifSearchEnabled: false,
                onInsertEmoji: (_) {},
                onStageGif: (_) {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final bar = find.byKey(const Key('composer-action-bar'));
    final oneLine = tester.getSize(bar).height;

    controller.text = 'first line\nsecond line\nthird line';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final mid = tester.getSize(find.byType(AnimatedSize)).height;
    await tester.pumpAndSettle();
    final threeLines = tester.getSize(bar).height;

    expect(threeLines, greaterThan(oneLine));
    expect(mid, greaterThan(oneLine), reason: 'the growth has set off');
    expect(mid, lessThan(threeLines), reason: 'and has not already arrived');
  });
}
