// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where the keystroke paste is a no-op (web, iOS) the pane must not consume Ctrl/Cmd+V, or the browser never fires the DOM `paste` event that carries the image bytes.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_design_system/design_system.dart';

import 'canvas_pane_harness.dart';

Future<bool> _chordReachesOutside(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey letter,
) async {
  debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  final fixture = CanvasPaneFixture();
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  var reached = false;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Focus(
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent && event.logicalKey == letter) {
              reached = true;
            }
            return KeyEventResult.ignored;
          },
          child: const Scaffold(body: CanvasPane(channelId: 'c1')),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyDownEvent(letter);
  await tester.sendKeyUpEvent(letter);
  await tester.sendKeyUpEvent(modifier);
  debugDefaultTargetPlatformOverride = null;
  return reached;
}

void main() {
  testWidgets('control: an unbound chord reaches an ancestor', (tester) async {
    expect(
      await _chordReachesOutside(
        tester,
        LogicalKeyboardKey.control,
        LogicalKeyboardKey.keyJ,
      ),
      isTrue,
    );
  });

  for (final modifier in [
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.meta,
  ]) {
    testWidgets(
      'the pane leaves ${modifier.keyLabel}+V unhandled when the keystroke '
      'paste is a no-op',
      (tester) async {
        expect(
          await _chordReachesOutside(tester, modifier, LogicalKeyboardKey.keyV),
          isTrue,
          reason:
              'the pane handled the paste chord, so a browser would '
              'preventDefault the keydown and never fire its paste event',
        );
      },
    );
  }
}
