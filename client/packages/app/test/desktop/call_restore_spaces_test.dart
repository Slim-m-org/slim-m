// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call keeps running in a Space that is not on screen, so quitting forgets
/// that Space's call and restarting brings that Space's call back. Either one
/// first ends a share's audio mix, which would pause media players if it went
/// with the process.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/desktop/self_update/self_update_controller.dart';
import 'package:slimm_app/src/desktop/update_check.dart';
import 'package:slimm_app/src/desktop/update_watch.dart';
import 'package:slimm_app/src/desktop/window_menu_button.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/space_scoped_preferences.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import '../features/accounts/account_host_harness.dart';
import '../support/async_wait.dart';
import 'support/desktop_shell_fixture.dart';
import 'support/fake_desktop_window_port.dart';

const _onScreen = 'https://first.example';
const _inCall = 'https://second.example';

class _InstallsAtOnce implements SelfUpdateController {
  @override
  Future<String?> install({
    required String currentVersion,
    InstallFormat? format,
    String? resolvedExecutable,
    String? os,
  }) async => '0.99.0';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CallToRestore? _recordOf(SharedPreferences prefs, String origin) =>
    CallToRestore.decode(
      prefs.getString(spaceScopedKey(origin, callRestoreKey)),
    );

/// The second Space is in a call while the first is on screen, with the record its watch wrote.
Future<void> _callInSecondSpace(AccountHarness h) async {
  final runtime = h.host.runtimeFor(_inCall)!;
  runtime.container.read(testCallProvider.notifier).state = const VoiceFlags(
    channelId: 'voice-1',
    state: VoiceSessionState.connected,
  );
  final restore = await runtime.container.read(callRestoreProvider.future);
  await restore.remember(channelId: 'voice-1', userId: 'bea', muted: false);
  await pumpEventQueueTimes();
}

Future<AccountHarness> _boot({
  Map<String, Object> prefs = const {},
  List<Override> overrides = const [],
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  CallRestore.resetClosing();
  final h = AccountHarness(extraOverrides: overrides);
  await h.seed(_onScreen, user: 'ann', active: true);
  await h.seed(_inCall, user: 'bea');
  await h.boot();
  await _callInSecondSpace(h);
  return h;
}

Future<(AccountHarness, FakeDesktopWindowPort)> _menu(
  WidgetTester tester, {
  ClientUpdate? update,
  Map<String, Object> prefs = const {},
  List<Override> overrides = const [],
}) async {
  late AccountHarness h;
  await tester.runAsync(() async {
    h = await _boot(
      prefs: prefs,
      overrides: [
        inSessionUpdateProvider.overrideWith((ref) => update),
        ...overrides,
      ],
    );
  });
  addTearDown(() => tester.runAsync(h.dispose));
  final port = FakeDesktopWindowPort();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.host.active!.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topRight,
            child: WindowMenuButton(port: port),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return (h, port);
}

Future<void> _choose(WidgetTester tester, String item) async {
  await tester.tap(
    find.byWidgetPredicate(
      (widget) =>
          widget is AppIconButton && widget.semanticLabel == 'Window menu',
    ),
  );
  await pumpFrames(tester);
  await tester.tap(find.text(item));
  await tester.runAsync(pumpEventQueueTimes);
  await pumpFrames(tester);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('quitting forgets the call in a Space that is not on screen', () async {
    final h = await _boot();
    addTearDown(h.dispose);
    final port = FakeDesktopWindowPort();
    final shell = shellFor(port);
    await shell.registerListenersAndTray(h.host.active!.container);

    await shell.quit(port);

    final prefs = await SharedPreferences.getInstance();
    expect(_recordOf(prefs, _inCall), isNull);
    expect(port.destroyCalls, 1);
  });

  test('quitting ends a share\'s audio mix before the window goes', () async {
    final port = FakeDesktopWindowPort();
    int? destroyedBefore;
    final shell = shellFor(
      port,
      beforeExit: () async => destroyedBefore = port.destroyCalls,
    );

    await shell.quit(port);

    expect(destroyedBefore, 0);
    expect(port.destroyCalls, 1);
  });

  testWidgets('Restart slim-m ends a share\'s audio mix before the new copy '
      'starts', (tester) async {
    late FakeDesktopWindowPort menuPort;
    int? relaunchedBefore;
    final shell = shellFor(
      null,
      beforeExit: () async => relaunchedBefore = menuPort.relaunchCalls,
    );
    final (_, port) = await _menu(
      tester,
      overrides: [desktopWindowShellProvider.overrideWithValue(shell)],
    );
    menuPort = port;

    await _choose(tester, 'Restart slim-m');

    expect(relaunchedBefore, 0);
    expect(port.relaunchCalls, 1);
  });

  testWidgets('Restart slim-m brings back the call in another Space', (
    tester,
  ) async {
    final (_, port) = await _menu(tester);

    await _choose(tester, 'Restart slim-m');

    final prefs = await SharedPreferences.getInstance();
    expect(_recordOf(prefs, _inCall)?.restart, isTrue);
    expect(port.relaunchCalls, 1);
  });

  testWidgets('Restart to update brings back the call in another Space', (
    tester,
  ) async {
    final (_, port) = await _menu(
      tester,
      update: const ClientUpdate(
        version: '0.99.0',
        releaseUrl: 'https://example.invalid/release',
        format: InstallFormat.rpm,
      ),
      prefs: {autoUpdateKey: true},
    );

    await _choose(tester, 'Restart to update to 0.99.0');

    final prefs = await SharedPreferences.getInstance();
    expect(_recordOf(prefs, _inCall)?.restart, isTrue);
    expect(port.relaunchCalls, 1);
  });

  testWidgets('an install waits while another Space is in a call', (
    tester,
  ) async {
    final (_, port) = await _menu(
      tester,
      update: const ClientUpdate(
        version: '0.99.0',
        releaseUrl: 'https://example.invalid/release',
        format: InstallFormat.tarball,
      ),
      overrides: [
        selfApplyAvailableProvider.overrideWithValue(true),
        selfUpdateProvider.overrideWith((ref) => _InstallsAtOnce()),
        appInfoProvider.overrideWith(
          (ref) async => PackageInfo(
            appName: 'slim-m',
            packageName: 'slimm',
            version: '0.98.0',
            buildNumber: '1',
          ),
        ),
      ],
    );

    await _choose(tester, 'Install 0.99.0');

    expect(port.relaunchCalls, 0, reason: 'the call in the other Space stays');
  });
}
