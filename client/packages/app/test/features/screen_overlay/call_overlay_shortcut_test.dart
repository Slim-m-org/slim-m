// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The overlay key is bound only where the overlay can be hosted, so the
/// browser and every other platform keep Ctrl+Shift+O, and it follows a remap.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/screen_overlay/widgets/call_overlay_shortcut.dart';
import 'package:slimm_platform/platform.dart';

Future<Map<ShortcutActivator, VoidCallback>> _bindings(
  WidgetTester tester, {
  required bool hosted,
}) async {
  late Map<ShortcutActivator, VoidCallback> found;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [screenOverlaySupportedProvider.overrideWithValue(hosted)],
      child: Consumer(
        builder: (context, ref, _) {
          found = callOverlayShortcutBindings(ref);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return found;
}

void main() {
  tearDown(() => userShortcutOverrides = const {});

  testWidgets('where the overlay can be hosted, one key is bound', (
    tester,
  ) async {
    final bindings = await _bindings(tester, hosted: true);
    final key = bindings.keys.single as SingleActivator;
    expect(
      (key.trigger, key.control, key.shift),
      (LogicalKeyboardKey.keyO, true, true),
    );
  });

  testWidgets('where it cannot, nothing is bound and the key is left alone', (
    tester,
  ) async {
    expect(await _bindings(tester, hosted: false), isEmpty);
  });

  testWidgets('a remapped chord is the one that is bound', (tester) async {
    const custom = SingleActivator(LogicalKeyboardKey.f8);
    userShortcutOverrides = {AppAction.toggleCallOverlay: custom};
    final bindings = await _bindings(tester, hosted: true);
    expect(bindings.keys.single, same(custom));
  });

  testWidgets('an unbound action binds nothing', (tester) async {
    userShortcutOverrides = {AppAction.toggleCallOverlay: null};
    expect(await _bindings(tester, hosted: true), isEmpty);
  });
}
