// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared hold that both the fullscreen video route and the canvas's
/// focused tile use to cover the whole display.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/window_fullscreen_hold.dart';
import 'package:slimm_app/src/features/voice/providers/fullscreen_video.dart';

import 'support/fake_desktop_window_port.dart';

void main() {
  late FakeDesktopWindowPort port;
  late ProviderContainer container;

  setUp(() {
    port = FakeDesktopWindowPort();
    DesktopWindowShell.debugPort = port;
    container = ProviderContainer();
  });
  tearDown(() {
    container.dispose();
    DesktopWindowShell.debugReset();
  });

  WindowFullscreenHold hold() => WindowFullscreenHold(
    container.read(fullscreenVideoActiveProvider.notifier),
  );

  test('entering fullscreens the window and hides the chrome, releasing '
      'gives both back', () async {
    DesktopWindowShell.debugActivate(frameless: true);
    final h = hold();

    await h.enter();
    expect(port.fullScreen, isTrue);
    expect(container.read(fullscreenVideoActiveProvider), isTrue);

    h.release();
    await Future<void>.delayed(Duration.zero);
    expect(port.fullScreen, isFalse);
    expect(container.read(fullscreenVideoActiveProvider), isFalse);
  });

  test('without a desktop shell it does nothing', () async {
    final h = hold();
    await h.enter();
    expect(port.fullScreen, isFalse);
    expect(container.read(fullscreenVideoActiveProvider), isFalse);
    expect(h.held, isFalse);
  });

  test('a second enter and a release with nothing held are no-ops', () async {
    DesktopWindowShell.debugActivate(frameless: true);
    final h = hold()..release();
    await Future<void>.delayed(Duration.zero);
    expect(port.fullScreen, isFalse);

    await h.enter();
    port.fullScreen = false;
    await h.enter();
    expect(port.fullScreen, isFalse, reason: 'already held, not re-entered');
  });

  test(
    'two holds on one window leave fullscreen only when both let go',
    () async {
      DesktopWindowShell.debugActivate(frameless: true);
      final route = hold();
      final tile = hold();

      await tile.enter();
      await route.enter();
      route.release();
      await Future<void>.delayed(Duration.zero);

      expect(
        port.fullScreen,
        isTrue,
        reason: 'the focused tile still wants it',
      );
      expect(container.read(fullscreenVideoActiveProvider), isTrue);

      tile.release();
      await Future<void>.delayed(Duration.zero);
      expect(port.fullScreen, isFalse);
      expect(container.read(fullscreenVideoActiveProvider), isFalse);
    },
  );
}
