// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A window dragged below the floor is sized back up to it.
///
/// The OS minimum is not honored under Wayland, so a window could be dragged
/// to a sliver. Since the chrome follows the window's size, that sliver now
/// renders the compact layout at a width nothing can lay out in, and
/// overflows. The controller holds the floor itself, once the real window is
/// in place.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/close_behavior.dart';
import 'package:slimm_app/src/desktop/desktop_window_controller.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';
import 'package:slimm_app/src/desktop/window_geometry_store.dart';

import 'support/fake_desktop_window_port.dart';

/// A port whose window actually takes the size it is asked for, after
/// [latency] like a real platform call.
class _CountingPort extends FakeDesktopWindowPort {
  Duration latency = Duration.zero;
  final sizes = <WindowSize>[];

  @override
  Future<WindowRect> getBounds() async {
    await Future<void>.delayed(latency);
    return super.getBounds();
  }

  @override
  Future<void> setSize(WindowSize size) async {
    sizes.add(size);
    await Future<void>.delayed(latency);
    bounds = WindowRect(
      x: bounds.x,
      y: bounds.y,
      width: size.width,
      height: size.height,
    );
  }
}

WindowRect _bounds(double width, double height) =>
    WindowRect(x: 10, y: 10, width: width, height: height);

Future<({_CountingPort port, DesktopWindowController controller})> _open({
  bool realWindow = true,
}) async {
  SharedPreferences.setMockInitialValues({});
  final port = _CountingPort();
  final controller = DesktopWindowController(
    port: port,
    store: WindowGeometryStore(await SharedPreferences.getInstance()),
    platform: DesktopPlatform.linux,
    trayAvailable: () async => true,
    geometryPersistenceEnabled: realWindow,
  )..start();
  addTearDown(controller.dispose);
  return (port: port, controller: controller);
}

Future<void> _drag(_CountingPort port, WindowRect to) async {
  port.bounds = to;
  port.emit(DesktopWindowEventKind.resize);
  await pumpEventQueue();
}

void main() {
  const floor = WindowSize(width: 800, height: 600);

  test('the floor this holds is the one the app sets', () {
    expect(WindowGeometry.minimumWindowSize.width, floor.width);
    expect(WindowGeometry.minimumWindowSize.height, floor.height);
  });

  test('a drag below the floor in both ways is sized back up to it', () async {
    final open = await _open();

    await _drag(open.port, _bounds(105, 170));

    expect(open.port.sizes.single.width, floor.width);
    expect(open.port.sizes.single.height, floor.height);
  });

  test('only a dimension under the floor is raised', () async {
    final open = await _open();

    await _drag(open.port, _bounds(1030, 170));
    await _drag(open.port, _bounds(105, 890));

    expect(open.port.sizes[0].width, 1030);
    expect(open.port.sizes[0].height, floor.height);
    expect(open.port.sizes[1].width, floor.width);
    expect(open.port.sizes[1].height, 890);
  });

  test('a window at or above the floor is left alone', () async {
    final open = await _open();

    await _drag(open.port, _bounds(800, 600));
    await _drag(open.port, _bounds(1280, 720));

    expect(open.port.sizes, isEmpty);
  });

  test('the splash, smaller than the floor, is left alone', () async {
    final open = await _open(realWindow: false);

    await _drag(open.port, _bounds(380, 460));

    expect(open.port.sizes, isEmpty);
  });

  test('the floor applies once the real window is in place', () async {
    final open = await _open(realWindow: false);
    await _drag(open.port, _bounds(380, 460));

    open.controller.enableGeometryPersistence();
    await _drag(open.port, _bounds(380, 460));

    expect(open.port.sizes, hasLength(1));
  });

  test('a maximized or fullscreen window is never resized', () async {
    final open = await _open();
    open.port.maximized = true;
    await _drag(open.port, _bounds(105, 170));
    open.port
      ..maximized = false
      ..fullScreen = true;
    await _drag(open.port, _bounds(105, 170));

    expect(open.port.sizes, isEmpty);
  });

  test('resize events during a slow resize ask for one resize', () async {
    final open = await _open();
    open.port
      ..latency = const Duration(milliseconds: 20)
      ..bounds = _bounds(105, 170);

    for (var i = 0; i < 5; i++) {
      open.port.emit(DesktopWindowEventKind.resize);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));

    expect(open.port.sizes, hasLength(1));
  });
}
