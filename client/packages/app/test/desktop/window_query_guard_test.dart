// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// No window query reaches the native plugin while its window cannot answer.
///
/// The Linux `window_manager` plugin dereferences its GtkWindow unchecked, so a
/// query then segfaults the whole app.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';
import 'package:slimm_app/src/desktop/window_maximized_tracker.dart';
import 'package:slimm_app/src/desktop/window_resize_frame.dart';

import 'support/fake_desktop_window_port.dart';

Future<void> _turn() => Future<void>.delayed(Duration.zero);

void main() {
  test('the tracker does not query a window that cannot answer', () async {
    final port = FakeDesktopWindowPort()..queryable = false;
    final tracker = WindowMaximizedTracker(port);
    await tracker.refresh();
    await tracker.toggle();
    port.emit(DesktopWindowEventKind.maximize);
    await _turn();
    expect(port.nativeQueryCalls, 0);
    expect(port.maximizeCalls + port.unmaximizeCalls, 0);
    tracker.dispose();
  });

  test('a disposed tracker never queries again', () async {
    final port = FakeDesktopWindowPort();
    final tracker = WindowMaximizedTracker(port);
    await _turn();
    tracker.dispose();
    port.queryable = false;
    await tracker.refresh();
    await tracker.toggle();
    expect(port.nativeQueryCalls, 0);
  });

  test('the tracker resyncs when the window shows again', () async {
    final port = FakeDesktopWindowPort()..queryable = false;
    final tracker = WindowMaximizedTracker(port);
    port.maximized = true;
    port.queryable = true;
    port.emit(DesktopWindowEventKind.show);
    await _turn();
    await _turn();
    expect(tracker.maximized, isTrue);
    tracker.dispose();
  });

  testWidgets('the resize frame does not query a window that cannot answer', (
    tester,
  ) async {
    final port = FakeDesktopWindowPort()..queryable = false;
    await tester.pumpWidget(MaterialApp(home: WindowResizeFrame(port: port)));
    await tester.pump();
    expect(port.nativeQueryCalls, 0);
  });

  test('the controller skips geometry and minimum-size queries', () async {
    SharedPreferences.setMockInitialValues({});
    final store = WindowGeometryStore(await SharedPreferences.getInstance());
    final port = FakeDesktopWindowPort()..queryable = false;
    final controller = DesktopWindowController(
      port: port,
      store: store,
      platform: DesktopPlatform.linux,
      trayAvailable: () async => true,
      geometryPersistenceEnabled: true,
      debounce: Duration.zero,
    )..start();
    port.emit(DesktopWindowEventKind.resize);
    port.emit(DesktopWindowEventKind.maximize);
    await _turn();
    await _turn();
    await controller.requestClose();
    expect(port.nativeQueryCalls, 0);
    controller.dispose();
  });
}
