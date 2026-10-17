// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [DesktopWindowController] reacts to a fake port's own events with no
/// real window anywhere - the debounce, the close-vs-minimise routing, and
/// the windowed-size-survives-maximize guard, all driven by [fakeAsync]
/// rather than a real clock.
///
/// Every controller under test here is constructed and started inside the
/// same [fakeAsync] callback that later emits events into it: a debounce
/// [Timer] takes its clock from the zone active when it is created, which is
/// the zone active when the triggering event is delivered to a stream
/// listener - the zone `start()` called `port.events.listen` in, not
/// whichever zone happens to call `port.emit` later. Constructing outside
/// [fakeAsync] silently creates a real, wall-clock timer that no `elapse`
/// call can ever advance.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';

import 'support/fake_desktop_window_port.dart';

Future<WindowGeometryStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  return WindowGeometryStore(await SharedPreferences.getInstance());
}

void main() {
  group('DesktopWindowController geometry persistence', () {
    test('several resize events within the debounce write only once', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      DesktopWindowController? controller;

      fakeAsync((async) {
        controller = DesktopWindowController(
          port: port,
          store: store,
          platform: DesktopPlatform.linux,
          trayAvailable: () async => true,
          geometryPersistenceEnabled: true,
        )..start();

        port.emit(DesktopWindowEventKind.resize);
        async.elapse(const Duration(milliseconds: 100));
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(const Duration(milliseconds: 100));
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(desktopGeometryDebounce - const Duration(milliseconds: 1));

        expect(
          store.read(),
          isNull,
          reason: 'the debounce has not yet elapsed since the last event',
        );

        async.elapse(const Duration(milliseconds: 2));
      });

      final saved = store.read();
      expect(saved, isNotNull);
      expect(saved!.windowedSize, const WindowSize(width: 1280, height: 720));
      controller?.dispose();
    });

    test(
      'a resize followed by silence writes after exactly one debounce',
      () async {
        final port = FakeDesktopWindowPort();
        final store = await _store();
        DesktopWindowController? controller;

        fakeAsync((async) {
          controller = DesktopWindowController(
            port: port,
            store: store,
            platform: DesktopPlatform.linux,
            trayAvailable: () async => true,
            geometryPersistenceEnabled: true,
          )..start();

          port.emit(DesktopWindowEventKind.resize);
          async.elapse(desktopGeometryDebounce);
        });

        expect(store.read(), isNotNull);
        controller?.dispose();
      },
    );

    test('maximizing keeps the previously stored windowed size and position, '
        'and only flips the run state', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      await store.write(
        const WindowGeometry(
          windowedSize: WindowSize(width: 900, height: 600),
          position: WindowRect(x: 5, y: 5, width: 900, height: 600),
        ),
      );
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => true,
        positionSupported: () => true,
        geometryPersistenceEnabled: true,
      )..start();

      port.maximized = true;
      // A maximized getBounds() answers the display-covering rect.
      port.bounds = const WindowRect(x: 0, y: 0, width: 1920, height: 1080);
      port.emit(DesktopWindowEventKind.maximize);
      await Future<void>.delayed(Duration.zero);

      final saved = store.read()!;
      expect(saved.runState, WindowRunState.maximized);
      expect(saved.windowedSize, const WindowSize(width: 900, height: 600));
      expect(saved.position?.x, 5);
      controller.dispose();
    });

    test(
      'a resize event while geometry persistence is disabled writes nothing, '
      'even once the debounce fully elapses',
      () async {
        final port = FakeDesktopWindowPort();
        final store = await _store();
        DesktopWindowController? controller;

        fakeAsync((async) {
          // geometryPersistenceEnabled defaults to false: this is the splash.
          controller = DesktopWindowController(
            port: port,
            store: store,
            platform: DesktopPlatform.linux,
            trayAvailable: () async => true,
          )..start();

          port.emit(DesktopWindowEventKind.resize);
          async.elapse(desktopGeometryDebounce);
        });

        expect(store.read(), isNull);
        controller?.dispose();
      },
    );

    test('a maximize event while geometry persistence is disabled writes '
        'nothing either, since it bypasses the debounce entirely', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => true,
      )..start();

      port.maximized = true;
      port.emit(DesktopWindowEventKind.maximize);
      await Future<void>.delayed(Duration.zero);

      expect(store.read(), isNull);
      controller.dispose();
    });

    test('a write scheduled while persistence is disabled and firing after it '
        'is enabled reflects the bounds at fire time, not the splash bounds '
        'in effect when the event that scheduled it fired', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      port.bounds = const WindowRect(x: 45, y: 45, width: 480, height: 340);
      DesktopWindowController? controller;

      fakeAsync((async) {
        controller = DesktopWindowController(
          port: port,
          store: store,
          platform: DesktopPlatform.linux,
          trayAvailable: () async => true,
        )..start();

        // The splash resizes/centres itself; persistence is still off.
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(desktopGeometryDebounce - const Duration(milliseconds: 1));

        // Handoff completes: the real window is resized, then persistence enables - the order prepareHandoff and registerListenersAndTray already run in.
        port.bounds = const WindowRect(x: 40, y: 40, width: 1280, height: 720);
        controller!.enableGeometryPersistence();

        // The debounce timer scheduled by the splash-era resize now fires.
        async.elapse(const Duration(milliseconds: 1));
      });

      final saved = store.read();
      expect(saved, isNotNull);
      expect(saved!.windowedSize, const WindowSize(width: 1280, height: 720));
      controller?.dispose();
    });

    test('a normal resize after persistence is enabled still persists, so the '
        'gate does not break the feature it protects', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      DesktopWindowController? controller;

      fakeAsync((async) {
        controller = DesktopWindowController(
          port: port,
          store: store,
          platform: DesktopPlatform.linux,
          trayAvailable: () async => true,
          geometryPersistenceEnabled: true,
        )..start();

        port.bounds = const WindowRect(
          x: 100,
          y: 100,
          width: 1024,
          height: 768,
        );
        port.emit(DesktopWindowEventKind.resize);
        async.elapse(desktopGeometryDebounce);
      });

      final saved = store.read();
      expect(saved, isNotNull);
      expect(saved!.windowedSize, const WindowSize(width: 1024, height: 768));
      controller?.dispose();
    });
  });

  group('DesktopWindowController close routing', () {
    test(
      'a close event on Linux with a tray hides rather than minimises',
      () async {
        final port = FakeDesktopWindowPort();
        final store = await _store();
        final controller = DesktopWindowController(
          port: port,
          store: store,
          platform: DesktopPlatform.linux,
          trayAvailable: () async => true,
        )..start();

        port.emit(DesktopWindowEventKind.close);
        await Future<void>.delayed(Duration.zero);

        expect(port.hideCalls, 1);
        expect(port.minimizeCalls, 0);
        controller.dispose();
      },
    );

    test('a close event on Linux with no tray host minimises, never a hide '
        'with no way back', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => false,
      )..start();

      port.emit(DesktopWindowEventKind.close);
      await Future<void>.delayed(Duration.zero);

      expect(port.minimizeCalls, 1);
      expect(port.hideCalls, 0);
      controller.dispose();
    });

    test(
      'requestClose runs the same routing a native close event would',
      () async {
        final port = FakeDesktopWindowPort();
        final store = await _store();
        final controller = DesktopWindowController(
          port: port,
          store: store,
          platform: DesktopPlatform.linux,
          trayAvailable: () async => false,
        )..start();

        await controller.requestClose();

        expect(port.minimizeCalls, 1);
        controller.dispose();
      },
    );
  });

  group('DesktopWindowController onShow', () {
    test('fires once per show event, and not for any other event', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      var showCount = 0;
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => true,
        onShow: (_) => showCount++,
      )..start();

      port.emit(DesktopWindowEventKind.show);
      port.emit(DesktopWindowEventKind.maximize);
      await Future<void>.delayed(Duration.zero);

      expect(showCount, 1);
      controller.dispose();
    });

    test('carries null when no close has been routed yet', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      CloseAction? seen = CloseAction.hideToTray;
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => true,
        onShow: (action) => seen = action,
      )..start();

      port.emit(DesktopWindowEventKind.show);
      await Future<void>.delayed(Duration.zero);

      expect(seen, isNull);
      controller.dispose();
    });

    test('carries hideToTray, not minimizeToTaskbar, after a close that '
        'resolved to hiding', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      CloseAction? seen;
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => true,
        onShow: (action) => seen = action,
      )..start();

      port.emit(DesktopWindowEventKind.close);
      await Future<void>.delayed(Duration.zero);
      port.emit(DesktopWindowEventKind.show);
      await Future<void>.delayed(Duration.zero);

      expect(seen, CloseAction.hideToTray);
      controller.dispose();
    });

    test('carries minimizeToTaskbar, not hideToTray, after a close that '
        'resolved to minimising', () async {
      final port = FakeDesktopWindowPort();
      final store = await _store();
      CloseAction? seen;
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => false,
        onShow: (action) => seen = action,
      )..start();

      port.emit(DesktopWindowEventKind.close);
      await Future<void>.delayed(Duration.zero);
      port.emit(DesktopWindowEventKind.show);
      await Future<void>.delayed(Duration.zero);

      expect(seen, CloseAction.minimizeToTaskbar);
      controller.dispose();
    });
  });
}
