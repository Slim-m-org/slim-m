// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the anchored emoji picker opens relative to the button that opened
/// it: below when it fits, above when it does not, never over the button.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show CustomEmoji;
import 'package:slimm_app/src/features/emoji/widgets/emoji_picker.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/async_wait.dart';

const _trigger = Key('picker-trigger');

Future<({Rect button, Rect panel})> _open(
  WidgetTester tester,
  Alignment at,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 600);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        customEmojiProvider.overrideWith((ref) => const <CustomEmoji>[]),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Align(
            alignment: at,
            child: EmojiPickerButton(
              alignEnd: true,
              onSelect: (_) {},
              triggerBuilder: (context, toggle) => TextButton(
                key: _trigger,
                onPressed: toggle,
                child: const Text('Emoji'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.byKey(_trigger));
  await pumpFrames(tester, frames: 20);
  return (
    button: tester.getRect(find.byKey(_trigger)),
    panel: tester.getRect(find.byWidgetPredicate((w) => w is EmojiPickerPanel)),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('with room below its button the picker opens under it', (
    tester,
  ) async {
    final (:button, :panel) = await _open(tester, const Alignment(0.5, -0.8));

    expect(panel.top, greaterThanOrEqualTo(button.bottom));
    expect(panel.right, moreOrLessEquals(button.right, epsilon: 1));
  });

  testWidgets('without room below it opens above, clear of its own button', (
    tester,
  ) async {
    final (:button, :panel) = await _open(tester, const Alignment(0.5, 0.6));

    expect(panel.bottom, lessThanOrEqualTo(button.top));
    expect(panel.right, moreOrLessEquals(button.right, epsilon: 1));
  });
}
