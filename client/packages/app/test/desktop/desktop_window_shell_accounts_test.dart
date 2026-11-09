// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// With several Spaces signed in, the window acts on the settings of the one
/// on screen: its Close to tray choice and the place its first-run notice shows.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/first_run_tray_notice.dart';
import 'package:slimm_app/src/desktop/providers/close_to_tray_preference.dart';
import 'package:slimm_app/src/providers/startup_restores.dart';

import '../features/accounts/account_host_harness.dart';
import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  late FakeDesktopWindowPort port;
  late DesktopWindowShell shell;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    port = FakeDesktopWindowPort();
    shell = shellFor(port);
    await shell.registerListenersAndTray(h.host.active!.container);
  });
  tearDown(() async => h.dispose());

  test(
    'closing quits when Close to tray was turned off in the Space on screen',
    () async {
      await h.host
          .runtimeFor(_b)!
          .container
          .read(closeToTrayProvider.notifier)
          .set(false);
      await h.host.switchTo(_b);

      await shell.windowController!.requestClose();

      expect(port.destroyCalls, 1);
    },
  );

  test(
    'closing keeps the app running while the Space on screen keeps it on',
    () async {
      await h.host
          .runtimeFor(_b)!
          .container
          .read(closeToTrayProvider.notifier)
          .set(false);

      await shell.windowController!.requestClose();

      expect(port.destroyCalls, 0);
      expect(port.hideCalls + port.minimizeCalls, 1);
    },
  );

  test('a Space shown later reads the choice made in another', () async {
    await h.host
        .runtimeFor(_b)!
        .container
        .read(closeToTrayProvider.notifier)
        .set(false);
    final first = h.host.runtimeFor(_a)!.container;

    await resyncSharedPreferences(first);

    expect(first.read(closeToTrayProvider), isFalse);
  });

  test('the first-run notice appears in the Space on screen', () async {
    await h.host.switchTo(_b);
    await shell.windowController!.requestClose();

    port.emit(DesktopWindowEventKind.show);
    await pumpEventQueueTimes();

    final first = h.host.runtimeFor(_a)!.container;
    final second = h.host.runtimeFor(_b)!.container;
    expect(first.read(firstRunTrayNoticeCloseActionProvider), isNull);
    expect(second.read(firstRunTrayNoticeCloseActionProvider), isNotNull);
  });
}
