// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tray's call controls follow the account the call is on.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/tray/desktop_tray_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';

import '../features/accounts/account_host_harness.dart';
import 'support/fake_desktop_window_port.dart';

const _channel = MethodChannel('tray_manager');
const _a = 'https://first.example';
const _b = 'https://second.example';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call);
          return true;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    await h.dispose();
  });

  List<String> lastLabels() {
    final menu =
        (calls.lastWhere((c) => c.method == 'setContextMenu').arguments
                as Map)['menu']
            as Map;
    return [for (final i in menu['items'] as List) i['label'] as String];
  }

  test('a call on another server still shows its controls and leave', () async {
    h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    final tray = DesktopTrayController(
      port: FakeDesktopWindowPort(),
      container: h.host.active!.container,
      host: h.host,
    );
    await tray.start();
    addTearDown(tray.dispose);
    expect(lastLabels(), isNot(contains('Leave call')));

    h.host.runtimeFor(_b)!.container.read(testCallProvider.notifier).state =
        connectedCall;
    await pumpEventQueueTimes();

    expect(h.host.active!.account!.origin, _a);
    expect(lastLabels(), contains('Leave call'));
  });

  test('the menu clears when the call ends', () async {
    h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    final b = h.host.runtimeFor(_b)!;
    b.container.read(testCallProvider.notifier).state = connectedCall;
    await pumpEventQueueTimes();
    final tray = DesktopTrayController(
      port: FakeDesktopWindowPort(),
      container: h.host.active!.container,
      host: h.host,
    );
    await tray.start();
    addTearDown(tray.dispose);
    expect(lastLabels(), contains('Leave call'));

    b.container.read(testCallProvider.notifier).state = const VoiceFlags();
    await pumpEventQueueTimes();

    expect(lastLabels(), isNot(contains('Leave call')));
  });
}
