// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Quitting loses no geometry, runs once, and cannot be stopped by a failing step.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';

import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

const _first = WindowRect(x: 10, y: 10, width: 1100, height: 700);
const _latest = WindowRect(x: 20, y: 30, width: 1400, height: 900);

void main() {
  test(
    'flush waits for a write in flight and then stores the latest bounds',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = WindowGeometryStore(await SharedPreferences.getInstance());
      final gate = Completer<void>();
      final port = FakeDesktopWindowPort()
        ..bounds = _first
        ..boundsGate = gate.future;
      final controller = DesktopWindowController(
        port: port,
        store: store,
        platform: DesktopPlatform.linux,
        trayAvailable: () async => true,
        geometryPersistenceEnabled: true,
        positionSupported: () => true,
        debounce: const Duration(milliseconds: 10),
      )..start();
      addTearDown(controller.dispose);

      port.emit(DesktopWindowEventKind.move);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      var flushed = false;
      final flushing = controller.flush().then((_) => flushed = true);
      port.bounds = _latest;
      await Future<void>.delayed(Duration.zero);
      expect(flushed, isFalse);

      gate.complete();
      await flushing;
      expect(
        store.read()!.windowedSize,
        const WindowSize(width: 1400, height: 900),
      );
    },
  );

  test('two quits destroy the window once', () async {
    final port = FakeDesktopWindowPort();
    final shell = shellFor(
      port,
      beforeExit: () async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      },
    );
    await Future.wait([shell.quit(port), shell.quit(port)]);
    expect(port.destroyCalls, 1);
  });

  test('a failing step does not stop the window from closing', () async {
    final port = FakeDesktopWindowPort();
    final shell = shellFor(port, beforeExit: () async => throw StateError('x'));
    await shell.quit(port);
    expect(port.destroyCalls, 1);
  });

  test('a step that never finishes does not keep the window open', () async {
    final port = FakeDesktopWindowPort();
    final shell = shellFor(
      port,
      beforeExit: () => Completer<void>().future,
      quitStepTimeout: const Duration(milliseconds: 10),
    );
    await shell.quit(port);
    expect(port.destroyCalls, 1);
  });

  test('a window that cannot be destroyed forces the process out', () async {
    var forced = 0;
    final port = _ThrowingDestroy();
    final shell = shellFor(port, forceExit: () => forced++);
    await shell.quit(port);
    expect(forced, 1);
  });
}

class _ThrowingDestroy extends FakeDesktopWindowPort {
  @override
  Future<void> destroy() async => throw StateError('gone');
}
