// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every account the app opens shares the services that are one per process.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host_factory.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/push/providers/notification_tap_router.dart';
import 'package:slimm_app/src/push/providers/push_channel_providers.dart';
import 'package:slimm_app/src/providers/session_provider.dart';

class _CountingShell extends DesktopWindowShell {
  int raises = 0;

  @override
  Future<void> raise() async => raises++;
}

void main() {
  test('every account in one tab claims the same tab id', () {
    final host = createAccountHost(
      DesktopWindowShell(),
      Uri.parse(officialServer),
    );
    ProviderContainer open() {
      final container = host.createContainer(
        AccountSlot(chooseServer: (_, _) => throw UnimplementedError()),
      );
      addTearDown(container.dispose);
      return container;
    }

    expect(open().read(crossTabProvider), same(open().read(crossTabProvider)));
  });

  test('the push channels outlive the container that first read them', () {
    final host = createAccountHost(
      DesktopWindowShell(),
      Uri.parse(officialServer),
    );
    ProviderContainer open() => host.createContainer(
      AccountSlot(chooseServer: (_, _) => throw UnimplementedError()),
    );
    final first = open();
    final second = open();
    addTearDown(second.dispose);

    final apns = first.read(apnsTokenChannelProvider);
    final taps = first.read(notificationTapChannelProvider);
    final notifications = first.read(localNotificationsProvider);
    first.dispose();

    expect(second.read(apnsTokenChannelProvider), same(apns));
    expect(second.read(notificationTapChannelProvider), same(taps));
    expect(second.read(localNotificationsProvider), same(notifications));
    expect(
      taps.taps.listen((_) {}).cancel(),
      completes,
      reason: 'the tap stream stays open after the first container goes',
    );
  });

  test(
    'a click raises the window even when its payload names no channel',
    () async {
      final shell = _CountingShell();
      final host = createAccountHost(shell, Uri.parse(officialServer));

      await openNotificationTarget(shell, host, null);

      expect(shell.raises, 1);
    },
  );
}
