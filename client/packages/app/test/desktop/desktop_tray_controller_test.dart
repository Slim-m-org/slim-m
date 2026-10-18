// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Regression for the tray reaching every real launch with an icon but no
/// menu: `tray_manager`'s Linux plugin has no handler for `setToolTip`
/// (`tray_manager_plugin.cc` only implements `setTitle`), so the call threw
/// `MissingPluginException` and used to abort `DesktopTrayController.start()`
/// before it ever reached `setContextMenu` - confirmed live on the owner's
/// KDE session via `busctl`'s `GetLayout` on the exported dbusmenu object
/// showing zero children. This drives the real `start()` against a mocked
/// `tray_manager` channel that fails `setToolTip` the same way, and asserts
/// the context menu is still built.
///
/// Also covers a second regression on the released 0.61.0 build: the menu
/// rendered correctly but clicking any item did nothing. `tray_manager`
/// 0.5.3 fires `menuItem.onClick` from inside a loop over its registered
/// `TrayListener`s (`tray_manager.dart` line ~42); with none registered the
/// loop body never runs. The test below drives the plugin's own click event
/// (`onTrayMenuItemClick`, a call *from* the platform back into Dart) through
/// the mocked channel and asserts the click actually reached the port, not
/// just that the menu looks right.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/tray/desktop_tray_controller.dart';
import 'package:tray_manager/tray_manager.dart';

import '../features/voice/voice_controller_harness.dart';
import 'support/fake_desktop_window_port.dart';

const _channel = MethodChannel('tray_manager');

Future<void> _simulateMenuItemClick(int id) async {
  final call = MethodCall('onTrayMenuItemClick', {'id': id});
  final data = const StandardMethodCodec().encodeMethodCall(call);
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channel.name, data, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  /// The tooltip guard was written for the one call known to fail. The thing
  /// worth protecting is that the menu gets set at all: anything throwing
  /// ahead of it leaves the icon on the plugin's own empty placeholder menu
  /// for the whole session, which is the bug as a person meets it - an icon
  /// with no Show/Hide and no Quit - whichever call actually threw.
  ///
  /// Reported again from a real KDE session after the tooltip fix shipped,
  /// which is what says the guard was too narrow rather than wrong.
  test(
    'a backend that fails setIcon still gets a populated context menu',
    () async {
      final harness = VoiceHarness();
      harness.controllerWith(FakeSession(), voiceApi());
      addTearDown(harness.dispose);

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            if (call.method == 'setIcon') {
              throw PlatformException(code: 'no such asset');
            }
            return true;
          });

      final controller = DesktopTrayController(
        port: FakeDesktopWindowPort(),
        container: harness.container,
      );

      await controller.start();
      controller.dispose();

      final menuCall = calls.firstWhere(
        (call) => call.method == 'setContextMenu',
        orElse: () => throw StateError('no menu was ever set'),
      );
      final items =
          ((menuCall.arguments as Map)['menu'] as Map)['items'] as List;
      expect(items.first['label'], 'Show/Hide slim-m');
    },
  );

  /// The menu build itself is also contained, and for a second reason: it
  /// runs from two provider listeners where nothing awaits it, so an
  /// exception there would be unhandled rather than merely fatal to start.
  test(
    'a backend that fails setContextMenu does not take start down',
    () async {
      final harness = VoiceHarness();
      harness.controllerWith(FakeSession(), voiceApi());
      addTearDown(harness.dispose);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            if (call.method == 'setContextMenu') {
              throw PlatformException(code: 'no tray host');
            }
            return true;
          });

      final controller = DesktopTrayController(
        port: FakeDesktopWindowPort(),
        container: harness.container,
      );

      await expectLater(controller.start(), completes);
      controller.dispose();
    },
  );

  for (final (windows, extension) in [(true, '.ico'), (false, '.png')]) {
    test(
      'start sets a $extension tray icon when windows is $windows',
      () async {
        final harness = VoiceHarness();
        harness.controllerWith(FakeSession(), voiceApi());
        addTearDown(harness.dispose);
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_channel, (call) async {
              calls.add(call);
              return true;
            });
        final controller = DesktopTrayController(
          port: FakeDesktopWindowPort(),
          container: harness.container,
          windows: windows,
        );

        await controller.start();
        controller.dispose();

        final icon = calls.firstWhere((call) => call.method == 'setIcon');
        expect((icon.arguments as Map)['iconPath'], endsWith(extension));
      },
    );
  }

  test('a backend with no setToolTip handler still gets a populated context '
      'menu', () async {
    final harness = VoiceHarness();
    harness.controllerWith(FakeSession(), voiceApi());
    addTearDown(harness.dispose);

    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          if (call.method == 'setToolTip') {
            throw MissingPluginException('setToolTip: linux has none');
          }
          return true;
        });

    final controller = DesktopTrayController(
      port: FakeDesktopWindowPort(),
      container: harness.container,
    );

    await controller.start();
    controller.dispose();

    expect(calls.map((call) => call.method), contains('setContextMenu'));
    final menuCall = calls.firstWhere(
      (call) => call.method == 'setContextMenu',
    );
    final menu = (menuCall.arguments as Map)['menu'] as Map;
    final items = menu['items'] as List;
    expect(items, isNotEmpty);
    expect(items.first['label'], 'Show/Hide slim-m');
  });

  test(
    'clicking the Show/Hide menu item actually reaches the window port',
    () async {
      final harness = VoiceHarness();
      harness.controllerWith(FakeSession(), voiceApi());
      addTearDown(harness.dispose);

      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            calls.add(call);
            return true;
          });

      final port = FakeDesktopWindowPort()..visible = true;
      final controller = DesktopTrayController(
        port: port,
        container: harness.container,
      );

      await controller.start();
      addTearDown(controller.dispose);

      expect(TrayManager.instance.hasListeners, isTrue);

      final menuCall = calls.firstWhere(
        (call) => call.method == 'setContextMenu',
      );
      final menu = (menuCall.arguments as Map)['menu'] as Map;
      final items = menu['items'] as List;
      final showHideId = items.first['id'] as int;

      await _simulateMenuItemClick(showHideId);

      expect(port.hideCalls, 1);
    },
  );
}
