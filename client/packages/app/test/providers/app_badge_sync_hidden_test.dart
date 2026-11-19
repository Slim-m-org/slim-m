// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The taskbar badge counts what arrives while the window is minimised, when
/// Flutter draws no frames and a derived provider never refreshes.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/app_badge_sync.dart';
import 'package:slimm_app/src/push/providers/push_channel_providers.dart';
import 'package:slimm_platform/platform.dart';

import '../features/accounts/account_host_harness.dart';
import '../features/accounts/account_switcher_support.dart';
import '../support/window_lifecycle.dart';

const _taskbar = MethodChannel(taskbarAttentionChannelName);

void main() {
  testWidgets('a message for a minimised window raises the taskbar badge', (
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
      await h.seed('https://first.example', user: 'ann', active: true);
      await h.seed('https://second.example', user: 'bea');
      await h.boot();
    });
    addTearDown(() => tester.runAsync(h.dispose));
    final app = h.host.active!.container;
    await tester.pumpWidget(
      UncontrolledProviderScope(container: app, child: const SizedBox()),
    );
    final sync = app.listen(appBadgeSyncProvider, (_, _) {});
    addTearDown(sync.close);
    await tester.pump();
    expect(badges.last, 0);

    await hideTestWindow(tester);
    await seedUnread(tester, h, 'https://second.example');

    expect(badges.last, 1);
  });
}
