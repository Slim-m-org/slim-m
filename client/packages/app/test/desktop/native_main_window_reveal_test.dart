// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Windows the runner holds the main window cloaked from its first frame,
/// so the user never sees it before the splash is sized and frameless, and the
/// handoff cloaks it again while it takes its real size.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show VoidCallback;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/popout/popout_windowing.dart';

import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

class _FakeMainWindow implements NativeMainWindow {
  _FakeMainWindow(this.port);

  final FakeDesktopWindowPort port;
  final steps = <String>[];

  @override
  set onCloseRequested(VoidCallback? handler) {}

  @override
  Future<void> reveal() async => steps.add(
    'reveal (title bar hidden ${port.hideTitleBarCalls}, shown ${port.showCalls})',
  );

  @override
  Future<void> conceal() async =>
      steps.add('conceal (shown ${port.showCalls})');
}

/// Pumps frames until [work], which waits on frames of its own, is done.
Future<void> _settle(WidgetTester tester, Future<void> work) async {
  var done = false;
  unawaited(work.whenComplete(() => done = true));
  for (var i = 0; i < 20 && !done; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(done, isTrue);
}

void main() {
  testWidgets('the splash is revealed only once its frame is locked', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final window = _FakeMainWindow(port);
    final shell = shellFor(port, chrome: DesktopPlatform.windows)
      ..nativeWindow = window;

    await _settle(tester, shell.lockSplashChrome());

    expect(window.steps, ['reveal (title bar hidden 1, shown 0)']);
  });

  testWidgets('the handoff is cloaked from before the show until it painted', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort();
    final window = _FakeMainWindow(port);
    final shell = shellFor(port, chrome: DesktopPlatform.windows)
      ..nativeWindow = window;

    await _settle(tester, shell.revealAfterHandoff());

    expect(window.steps, [
      'conceal (shown 0)',
      'reveal (title bar hidden 0, shown 1)',
    ]);
  });
}
