// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On Windows the runner holds the main window hidden from its first frame
/// until the splash is sized and frameless, and the handoff then grows the
/// window in place instead of hiding it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show Color, Size, VoidCallback;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';
import 'package:slimm_app/src/desktop/window_view_size.dart';

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

  final backgrounds = <int>[];

  @override
  Future<void> setBackground(int argb) async => backgrounds.add(argb);

  @override
  Future<void> reveal() async => steps.add(
    'reveal (title bar hidden ${port.hideTitleBarCalls}, shown ${port.showCalls})',
  );
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

ProviderContainer _container() {
  final container = ProviderContainer();
  addTearDown(container.dispose);
  return container;
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

  testWidgets('on Windows the handoff grows the window in place', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final port = FakeDesktopWindowPort();
    final shell = shellFor(port, chrome: DesktopPlatform.windows);

    await _settle(tester, shell.prepareHandoff(_container()));

    expect(port.hideCalls, 0);
    expect(port.lastSize, isNotNull);
  });

  testWidgets('elsewhere the handoff still hides the window first', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final port = FakeDesktopWindowPort();
    final shell = shellFor(port, chrome: DesktopPlatform.linux);

    await _settle(tester, shell.prepareHandoff(_container()));

    expect(port.hideCalls, 1);
  });

  test('a frameless Windows view is measured against its borders', () {
    final inset = splashFrameInset(const Size(344, 252));
    expect(inset?.width, 16);
    expect(inset?.height, 8);
    final view = viewSizeFor(const WindowSize(width: 1280, height: 720), inset);
    expect(view?.width, 1264);
    expect(view?.height, 712);
  });

  test('the window gets the splash colour once per change', () {
    final port = FakeDesktopWindowPort();
    final window = _FakeMainWindow(port);
    final shell = shellFor(port, chrome: DesktopPlatform.windows)
      ..nativeWindow = window;

    shell.useNativeBackground(const Color(0xFF1E1F22));
    shell.useNativeBackground(const Color(0xFF1E1F22));
    shell.useNativeBackground(const Color(0xFFF5F5F7));

    expect(window.backgrounds, [0xFF1E1F22, 0xFFF5F5F7]);
  });

  test('a view that is not a splash gives no inset', () {
    expect(splashFrameInset(const Size(800, 600)), isNull);
    expect(splashFrameInset(null), isNull);
  });
}
