// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every account the app opens shares the services that are one per process.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/features/accounts/providers/account.dart';
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

  group('debug log routing', () {
    tearDown(() => AppLog.install(null));

    ({ProviderContainer a, ProviderContainer b}) twoAccounts() {
      final host = createAccountHost(
        DesktopWindowShell(),
        Uri.parse(officialServer),
      );
      ProviderContainer open(String server) {
        final slot = AccountSlot(
          chooseServer: (_, _) => throw UnimplementedError(),
        )..account = Account.forServer(Uri.parse(server));
        final container = host.createContainer(slot);
        addTearDown(container.dispose);
        return container;
      }

      final a = host.createFirst();
      addTearDown(a.dispose);
      a.read(accountSlotProvider)!.account = Account.forServer(
        Uri.parse('https://a.example'),
      );
      final b = open('https://b.example');
      a.read(debugLogProvider);
      b.read(debugLogProvider);
      AppLog.install(a.read(debugLogSinkProvider));
      return (a: a, b: b);
    }

    test('an unscoped record reaches only the on-screen account', () {
      final c = twoAccounts();

      AppLog.error(LogTag.sync, 'failed uri=https://a.example/channels/1');

      expect(
        c.a.read(debugLogProvider.notifier).asReport(),
        contains('a.example'),
      );
      expect(c.b.read(debugLogProvider), isEmpty);
    });

    test('work scoped to the launch account stays with it', () {
      final c = twoAccounts();

      scopedToAccount(c.b, () => AppLog.error(LogTag.sync, 'b failed'));

      expect(c.a.read(debugLogProvider), isEmpty);
      expect(c.b.read(debugLogProvider), hasLength(1));
    });
  });

  test('retiring one account leaves the others logging', () {
    final host = createAccountHost(
      DesktopWindowShell(),
      Uri.parse(officialServer),
    );
    final kept = host.createFirst();
    addTearDown(kept.dispose);
    kept.read(accountSlotProvider)!.account = Account.forServer(
      Uri.parse('https://a.example'),
    );
    final retired = host.createContainer(
      AccountSlot(chooseServer: (_, _) => throw UnimplementedError())
        ..account = Account.forServer(Uri.parse('https://b.example')),
    );
    kept.read(debugLogProvider);
    retired.read(debugLogProvider);
    AppLog.install(kept.read(debugLogSinkProvider));
    addTearDown(() => AppLog.install(null));

    retired.dispose();
    AppLog.error(LogTag.sync, 'failed uri=https://a.example/channels/1');

    expect(kept.read(debugLogProvider), hasLength(1));
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
