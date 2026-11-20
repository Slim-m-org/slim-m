// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The badge keeps counting after the account the app launched with is removed.
library;

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/active_account_mount.dart';
import 'package:slimm_app/src/providers/app_badge_sync.dart';
import 'package:slimm_app/src/push/providers/push_channel_providers.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/account_host_harness.dart';
import '../features/accounts/account_switcher_support.dart';

const _taskbar = MethodChannel(taskbarAttentionChannelName);
const _first = 'https://first.example';
const _second = 'https://second.example';

void main() {
  testWidgets('removing the launch account keeps the taskbar badge in sync', (
    tester,
  ) async {
    final badges = <Object?>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(_taskbar, (
      call,
    ) async {
      if (call.method == 'badge') badges.add(call.arguments);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        _taskbar,
        null,
      ),
    );
    final h = AccountHarness(
      extraOverrides: [
        taskbarAttentionProvider.overrideWithValue(
          TaskbarAttention(isWindows: true),
        ),
      ],
    );
    await tester.runAsync(() async {
      await h.seed(_first, user: 'ann', active: true);
      await h.seed(_second, user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    final launch = h.host.active!.container;
    final mount = ActiveAccountMount.start(h.host, launch, [
      appBadgeSyncProvider,
    ]);
    addTearDown(mount.dispose);
    await tester.pump();
    expect(badges.last, 0);

    await tester.runAsync(() => h.host.removeAccount(_first));
    await tester.pump();
    expect(() => launch.read(appBadgeSyncProvider), throwsStateError);
    await seedUnread(tester, h, _second);

    expect(badges.last, 1);
  });

  test('with no host the providers stay on the one container', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    var builds = 0;
    final probe = Provider<void>((ref) => builds++);
    final mount = ActiveAccountMount.start(null, container, [probe]);

    expect(builds, 1);
    expect(container.exists(probe), isTrue);
    mount.dispose();
  });
}
