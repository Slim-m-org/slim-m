// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared hold that both the fullscreen video route and the canvas's
/// focused tile use to cover the whole display.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/window_fullscreen_hold.dart';
import 'package:slimm_app/src/features/voice/providers/fullscreen_video.dart';
import 'package:slimm_app/src/providers/app_lifecycle.dart';

import 'support/fake_desktop_window_port.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
    WindowFullscreenHold.debugReset();
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

  test(
    'a window that was already fullscreen is left fullscreen on release',
    () async {
      DesktopWindowShell.debugActivate(frameless: true);
      port.fullScreen = true;
      final h = hold();

      await h.enter();
      h.release();
      await Future<void>.delayed(Duration.zero);

      expect(port.fullScreen, isTrue, reason: 'the person had F11 on already');
      expect(container.read(fullscreenVideoActiveProvider), isFalse);
    },
  );

  test(
    'a hold taken over in the same frame keeps the window fullscreen',
    () async {
      DesktopWindowShell.debugActivate(frameless: true);
      final old = hold();
      await old.enter();

      // A remount: the new pane's hold arrives before the old one lets go.
      final fresh = hold();
      final entering = fresh.enter();
      old.release();
      await entering;
      await Future<void>.delayed(Duration.zero);

      expect(port.fullScreen, isTrue);
      expect(container.read(fullscreenVideoActiveProvider), isTrue);
    },
  );

  test('the OS leaving fullscreen on its own releases the hold', () async {
    DesktopWindowShell.debugActivate(frameless: true);
    final h = hold();
    await h.enter();
    expect(WindowFullscreenHold.anyHeld, isTrue);

    port.fullScreen = false;
    port.emit(DesktopWindowEventKind.leaveFullScreen);
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(h.held, isFalse);
    expect(WindowFullscreenHold.anyHeld, isFalse);
    expect(
      container.read(fullscreenVideoActiveProvider),
      isFalse,
      reason: 'the title bar must come back with the window',
    );
  });

  test(
    'releasing while isFullScreen is still in flight does not fullscreen the window',
    () async {
      DesktopWindowShell.debugActivate(frameless: true);
      final h = hold();
      final entering = h.enter();
      h.release();
      await entering;
      await Future<void>.delayed(Duration.zero);

      expect(port.fullScreen, isFalse);
      expect(container.read(fullscreenVideoActiveProvider), isFalse);
    },
  );

  test(
    'minimising or hiding the window reports hidden even when the embedder only reports inactive, and showing restores it',
    () async {
      final life = container.read(appLifecycleProvider.notifier);
      life.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(container.read(appLifecycleProvider), AppLifecycleState.resumed);

      port.emit(DesktopWindowEventKind.minimize);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(appLifecycleProvider), AppLifecycleState.hidden);

      // Linux GTK reports inactive rather than hidden when minimised or hidden to tray.
      life.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(container.read(appLifecycleProvider), AppLifecycleState.hidden);

      port.emit(DesktopWindowEventKind.show);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(appLifecycleProvider), AppLifecycleState.inactive);

      life.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(container.read(appLifecycleProvider), AppLifecycleState.resumed);
    },
  );
}
