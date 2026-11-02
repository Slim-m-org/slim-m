// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Camera, share and leave are remappable like mute and deafen: they are
/// listed in Voice settings, follow the same conflict check and survive a
/// restart.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/shortcut_overrides.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_shortcuts_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _ctrlU = SingleActivator(LogicalKeyboardKey.keyU, control: true);
const _callActions = [
  AppAction.toggleCameraCall,
  AppAction.toggleShareCall,
  AppAction.leaveCall,
];

Future<ProviderContainer> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final container = ProviderContainer();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(child: VoiceShortcutsSection()),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  tearDown(() => userShortcutOverrides = const {});

  test('camera, share and leave are remappable', () {
    expect(remappableActions, containsAll(_callActions));
  });

  test('a chord taken by another call action is a conflict', () {
    final share = activatorFor(AppAction.toggleShareCall)! as SingleActivator;
    expect(
      shortcutConflict(
        chord: share,
        action: AppAction.leaveCall,
        pushToTalkKey: LogicalKeyboardKey.keyV,
      ),
      'Start or stop screen share',
    );
  });

  test('a remapped camera, share and leave chord survives storage', () {
    final decoded = decodeOverrides(
      encodeOverrides({for (final action in _callActions) action: _ctrlU}),
    );
    for (final action in _callActions) {
      expect(sameChord(decoded[action]!, _ctrlU), isTrue, reason: '$action');
    }
  });

  testWidgets('Voice settings lists a row for each, at its default chord', (
    tester,
  ) async {
    await _pump(tester);

    for (final name in ['Camera', 'Share', 'Leave']) {
      expect(find.text('$name shortcut'), findsOneWidget, reason: name);
    }
    expect(find.text('Ctrl+Shift+V'), findsOneWidget);
    expect(find.text('Ctrl+Shift+S'), findsOneWidget);
    expect(find.text('Ctrl+Shift+H'), findsOneWidget);
  });

  testWidgets('remapping Leave reaches the binding the shell listens on', (
    tester,
  ) async {
    final container = await _pump(tester);
    final change = find.text('Change');
    await tester.ensureVisible(change.last);
    await tester.tap(change.last);
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyU);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    await tester.pump();

    final now = activatorFor(AppAction.leaveCall)! as SingleActivator;
    expect(sameChord(now, _ctrlU), isTrue);
    expect(
      container.read(shortcutOverridesProvider)[AppAction.leaveCall],
      isNotNull,
    );
    expect(find.text('Ctrl+U'), findsOneWidget);
  });
}
