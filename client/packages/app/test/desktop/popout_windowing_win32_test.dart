// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Windows' pop-out: which hosts are offered one, that it is kept above every
/// other window through SetWindowPos, how it follows a feed's shape, and that a
/// close the main window hears on Windows acts as window_manager's would.
library;

// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:ffi' as ffi;

import 'package:flutter/services.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/popout/popout_windowing_native.dart';
import 'package:slimm_app/src/desktop/popout/popout_windowing_win32.dart';

class _FakeController extends RegularWindowController {
  _FakeController() : super.empty();

  Size size = const Size(640, 400);
  final sizes = <Size>[];
  bool destroyed = false;

  @override
  Size get contentSize => size;

  @override
  void setSize(Size size) {
    sizes.add(size);
    this.size = size;
  }

  @override
  void destroy() => destroyed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

typedef _Call = ({int window, int insertAfter, int flags});

({Win32PopOutWindow window, _FakeController controller, List<_Call> calls})
_popOut() {
  final controller = _FakeController();
  final calls = <_Call>[];
  final window = Win32PopOutWindow(
    controller,
    windowHandle: () => ffi.Pointer<ffi.Void>.fromAddress(0x1234),
    setWindowPos: (window, insertAfter, x, y, width, height, flags) {
      calls.add((
        window: window.address,
        insertAfter: insertAfter.address,
        flags: flags,
      ));
      return 1;
    },
  );
  return (window: window, controller: controller, calls: calls);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('which hosts offer a pop-out', () {
    test('Windows with the windowing flag gets the Win32 window', () {
      final factory = nativePopOutWindowFactory(
        windowing: true,
        linux: false,
        windows: true,
      );
      expect(factory, same(openWin32PopOutWindow));
    });

    test('Linux keeps its own window', () {
      final factory = nativePopOutWindowFactory(
        windowing: true,
        linux: true,
        windows: false,
      );
      expect(factory, isNotNull);
      expect(factory, isNot(same(openWin32PopOutWindow)));
    });

    test('no flag, or another desktop, gets none', () {
      expect(
        nativePopOutWindowFactory(
          windowing: false,
          linux: false,
          windows: true,
        ),
        isNull,
      );
      expect(
        nativePopOutWindowFactory(
          windowing: true,
          linux: false,
          windows: false,
        ),
        isNull,
      );
    });
  });

  test(
    'keepAbove makes the window topmost without moving or focusing it',
    () async {
      final rig = _popOut();
      await rig.window.keepAbove();
      expect(rig.calls, [(window: 0x1234, insertAfter: -1, flags: 0x13)]);
    },
  );

  test('the OS draws the frame, so the app draws none', () {
    expect(_popOut().window.drawsOwnFrame, isFalse);
  });

  test('destroy closes the native window', () {
    final rig = _popOut();
    rig.window.destroy();
    expect(rig.controller.destroyed, isTrue);
  });

  group('fitAspect', () {
    test('matches the height to the width for a new shape', () {
      final rig = _popOut();
      rig.window.fitAspect(16 / 9);
      expect(rig.controller.sizes, [const Size(640, 360)]);
    });

    test('leaves a user resize alone while the shape holds', () {
      final rig = _popOut();
      rig.window.fitAspect(16 / 9);
      rig.controller.size = const Size(900, 300);
      rig.window.fitAspect(16 / 9 + 0.001);
      expect(rig.controller.sizes, hasLength(1));
    });

    test('never goes below the minimum height', () {
      final rig = _popOut();
      rig.window.fitAspect(32);
      expect(rig.controller.sizes, [const Size(640, 160)]);
    });

    test('ignores a shape with no area', () {
      final rig = _popOut();
      rig.window.fitAspect(0);
      rig.window.fitAspect(double.nan);
      expect(rig.controller.sizes, isEmpty);
    });
  });

  group('a close the main window hears', () {
    late List<String> calls;

    setUp(() {
      calls = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('window_manager'), (
            call,
          ) async {
            calls.add(call.method);
            return true;
          });
    });

    test('is routed to the app once it holds close', () async {
      final port = WindowManagerDesktopWindowPort();
      final seen = <DesktopWindowEventKind>[];
      final sub = port.events.listen(seen.add);
      addTearDown(sub.cancel);

      await port.setPreventClose(true);
      port.onNativeCloseRequested();
      await pumpEventQueue();
      expect(seen, [DesktopWindowEventKind.close]);
      expect(calls, isNot(contains('destroy')));
    });

    test('quits before the app holds close', () async {
      final port = WindowManagerDesktopWindowPort();
      final seen = <DesktopWindowEventKind>[];
      final sub = port.events.listen(seen.add);
      addTearDown(sub.cancel);

      port.onNativeCloseRequested();
      await pumpEventQueue();
      expect(seen, isEmpty);
      expect(calls, contains('destroy'));
    });
  });
}
