// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Ctrl+K works without a pointer click first: focus that falls back to a
/// scope above the shell (setup closing, a field unfocused) is taken back.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';
import 'package:slimm_app/src/widgets/shell_focus_anchor.dart';

import '../support/window_lifecycle.dart';

Future<void> _ctrlK(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

class _Rig extends StatelessWidget {
  const _Rig({
    required this.setupOpen,
    required this.onOpen,
    this.field,
    this.window,
  });

  final bool setupOpen;
  final VoidCallback onOpen;
  final FocusNode? field;
  final AppLifecycleNotifier? window;

  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [if (window case final window?) windowLifecycle(window)],
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            ExcludeFocus(
              excluding: setupOpen,
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.keyK, control: true):
                      onOpen,
                },
                child: ShellFocusAnchor(
                  child: Center(
                    child: SizedBox(
                      width: 200,
                      child: TextField(focusNode: field),
                    ),
                  ),
                ),
              ),
            ),
            if (setupOpen)
              Align(
                alignment: Alignment.topLeft,
                child: TextButton(
                  onPressed: () {},
                  autofocus: true,
                  child: const Text('Continue'),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Ctrl+K works the moment first-run setup closes', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_Rig(setupOpen: true, onOpen: () => opened++));
    await tester.pump();
    await _ctrlK(tester);
    expect(opened, 0, reason: 'setup holds the keyboard while it is open');

    await tester.pumpWidget(_Rig(setupOpen: false, onOpen: () => opened++));
    await tester.pump();
    await _ctrlK(tester);

    expect(opened, 1);
  });

  testWidgets('Ctrl+K still works after a field gives up focus', (
    tester,
  ) async {
    var opened = 0;
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      _Rig(setupOpen: false, onOpen: () => opened++, field: field),
    );
    field.requestFocus();
    await tester.pump();
    field.unfocus();
    await tester.pump();
    await _ctrlK(tester);

    expect(opened, 1);
  });

  testWidgets('the anchor itself is never a Tab stop', (tester) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      _Rig(setupOpen: false, onOpen: () {}, field: field),
    );
    field.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('shell'));
  });

  testWidgets('a window that lost focus keeps its focus parked', (
    tester,
  ) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final field = FocusNode();
    addTearDown(field.dispose);
    // Blurred as the window reports it, with the embedder still saying resumed.
    final window = windowIn(AppLifecycleState.inactive);
    await tester.pumpWidget(
      _Rig(setupOpen: false, onOpen: () {}, field: field, window: window),
    );
    field.requestFocus();
    await tester.pump();
    field.unfocus();
    await tester.pump();

    expect(FocusManager.instance.primaryFocus?.debugLabel, isNot('shell'));
  });
}
