// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rules for what [DesktopWindowController] may write: no position where
/// the platform cannot report one, never the splash's size, and nothing lost
/// to a quit that lands inside the debounce.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/display_server.dart';
import 'package:slimm_app/src/desktop/window_fullscreen_hold.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';
import 'package:slimm_app/src/features/voice/providers/fullscreen_video.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

const _real = WindowRect(x: 100, y: 120, width: 1280, height: 720);

Future<WindowGeometryStore> _store([
  Map<String, Object> seed = const {},
]) async {
  SharedPreferences.setMockInitialValues(seed);
  return WindowGeometryStore(await SharedPreferences.getInstance());
}

DesktopWindowController _controller(
  FakeDesktopWindowPort port,
  WindowGeometryStore store, {
  required bool positionSupported,
  bool enabled = true,
  bool Function()? fullscreenHeld,
}) => DesktopWindowController(
  port: port,
  store: store,
  platform: DesktopPlatform.linux,
  trayAvailable: () async => true,
  geometryPersistenceEnabled: enabled,
  positionSupported: () => positionSupported,
  fullscreenHeld: fullscreenHeld ?? () => false,
)..start();

void main() {
  group('display server detection', () {
    test('Wayland is read from the session type or the display', () {
      expect(isWaylandSession({'XDG_SESSION_TYPE': 'wayland'}), isTrue);
      expect(isWaylandSession({'WAYLAND_DISPLAY': 'wayland-0'}), isTrue);
      expect(isWaylandSession({'XDG_SESSION_TYPE': 'x11'}), isFalse);
      expect(isWaylandSession({}), isFalse);
    });

    test('GDK_BACKEND=x11 under a Wayland session is X11', () {
      expect(
        isWaylandSession({
          'WAYLAND_DISPLAY': 'wayland-0',
          'GDK_BACKEND': 'x11',
        }),
        isFalse,
      );
    });

    test('only Linux on Wayland loses the position', () {
      final wayland = {'XDG_SESSION_TYPE': 'wayland'};
      expect(
        windowPositionSupported(isLinux: true, environment: wayland),
        isFalse,
      );
      expect(
        windowPositionSupported(isLinux: false, environment: wayland),
        isTrue,
      );
      expect(windowPositionSupported(isLinux: true, environment: {}), isTrue);
    });
  });

  group('what the controller writes', () {
    test('Wayland persists the size and never a position', () async {
      final port = FakeDesktopWindowPort()..bounds = _real;
      final store = await _store();
      late DesktopWindowController controller;
      fakeAsync((async) {
        controller = _controller(port, store, positionSupported: false);
        port.emit(DesktopWindowEventKind.move);
        async.elapse(desktopGeometryDebounce);
      });
      final saved = store.read()!;
      expect(saved.windowedSize, const WindowSize(width: 1280, height: 720));
      expect(saved.position, isNull);
      controller.dispose();
    });

    test('Wayland drops a position an older build stored', () async {
      final port = FakeDesktopWindowPort()..maximized = true;
      final store = await _store();
      await store.write(
        const WindowGeometry(
          windowedSize: WindowSize(width: 1000, height: 700),
          position: _real,
          runState: WindowRunState.windowed,
        ),
      );
      late DesktopWindowController controller;
      fakeAsync((async) {
        controller = _controller(port, store, positionSupported: false);
        port.emit(DesktopWindowEventKind.maximize);
        async.flushMicrotasks();
      });
      final saved = store.read()!;
      expect(saved.runState, WindowRunState.maximized);
      expect(saved.windowedSize, const WindowSize(width: 1000, height: 700));
      expect(saved.position, isNull);
      controller.dispose();
    });

    test('X11, Windows and macOS keep the position', () async {
      final port = FakeDesktopWindowPort()..bounds = _real;
      final store = await _store();
      late DesktopWindowController controller;
      fakeAsync((async) {
        controller = _controller(port, store, positionSupported: true);
        port.emit(DesktopWindowEventKind.move);
        async.elapse(desktopGeometryDebounce);
      });
      expect(store.read()!.position!.x, _real.x);
      expect(store.read()!.position!.y, _real.y);
      controller.dispose();
    });

    test('a size equal to the splash is never persisted', () async {
      final port = FakeDesktopWindowPort()
        ..bounds = WindowRect(
          x: 0,
          y: 0,
          width: kSplashWindowSize.width,
          height: kSplashWindowSize.height,
        );
      final store = await _store();
      late DesktopWindowController controller;
      fakeAsync((async) {
        controller = _controller(port, store, positionSupported: true);
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(desktopGeometryDebounce);
      });
      expect(store.read(), isNull);
      controller.dispose();
    });

    test('nothing is persisted before persistence is enabled', () async {
      final port = FakeDesktopWindowPort()..bounds = _real;
      final store = await _store();
      late DesktopWindowController controller;
      fakeAsync((async) {
        controller = _controller(
          port,
          store,
          positionSupported: true,
          enabled: false,
        );
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(desktopGeometryDebounce);
      });
      expect(store.read(), isNull);
      controller.dispose();
    });

    test(
      'a resize skipped before persistence lands when it turns on',
      () async {
        final port = FakeDesktopWindowPort()..bounds = _real;
        final store = await _store();
        late DesktopWindowController controller;
        fakeAsync((async) {
          controller = _controller(
            port,
            store,
            positionSupported: true,
            enabled: false,
          );
          port.emit(DesktopWindowEventKind.resize);
          async.elapse(desktopGeometryDebounce);
          controller.enableGeometryPersistence();
          async.flushMicrotasks();
        });
        expect(store.read()?.windowedSize.width, _real.width);
        controller.dispose();
      },
    );

    test('flush writes a pending debounced resize at once', () async {
      final port = FakeDesktopWindowPort()..bounds = _real;
      final store = await _store();
      late DesktopWindowController controller;
      fakeAsync((async) {
        controller = _controller(port, store, positionSupported: true);
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(const Duration(milliseconds: 100));
        expect(store.read(), isNull);
        controller.flush();
        async.flushMicrotasks();
      });
      expect(
        store.read()!.windowedSize,
        const WindowSize(width: 1280, height: 720),
      );
      controller.dispose();
    });
  });

  group('quit', () {
    test('flushes the pending write before the window is destroyed', () async {
      final port = FakeDesktopWindowPort()..bounds = _real;
      final store = await _store();
      final shell = shellFor(port, position: () => true);
      final container = ProviderContainer(
        overrides: [
          preferencesProvider.overrideWith(
            (ref) => SharedPreferences.getInstance(),
          ),
        ],
      );
      addTearDown(container.dispose);

      fakeAsync((async) {
        shell.registerListenersAndTray(container);
        async.flushMicrotasks();
        shell.windowController?.enableGeometryPersistence();
        port.emit(DesktopWindowEventKind.move);
        async.elapse(const Duration(milliseconds: 100));
        expect(store.read(), isNull);

        shell.quit(port);
        async.flushMicrotasks();
      });

      expect(store.read()!.position!.x, _real.x);
      expect(store.read()!.position!.y, _real.y);
      expect(port.destroyCalls, 1);
    });
  });

  test(
    'a window a call tile holds fullscreen is not saved as fullscreen',
    () async {
      final port = FakeDesktopWindowPort()..fullScreen = true;
      final shell = shellFor(port, active: true, frameless: true);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final hold = WindowFullscreenHold(
        container.read(fullscreenVideoActiveProvider.notifier),
        shell,
      );
      await hold.enter();
      final store = await _store();
      await store.write(
        const WindowGeometry(
          windowedSize: WindowSize(width: 1000, height: 700),
          runState: WindowRunState.windowed,
        ),
      );
      final controller = _controller(
        port,
        store,
        positionSupported: true,
        fullscreenHeld: () => shell.fullscreenHolds.any,
      );
      port.emit(DesktopWindowEventKind.fullScreen);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        store.read()!.runState,
        WindowRunState.windowed,
        reason: 'quitting with a tile focused must not relaunch fullscreen',
      );
      controller.dispose();
    },
  );
}
