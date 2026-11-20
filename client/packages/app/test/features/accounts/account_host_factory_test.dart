// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every account the app opens shares the services that are one per process.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/desktop_window_shell.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host_factory.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/providers/session_provider.dart';

void main() {
  test('every account in one tab claims the same tab id', () {
    final host = createAccountHost(DesktopWindowShell());
    ProviderContainer open() {
      final container = host.createContainer(
        AccountSlot(chooseServer: (_, _) => throw UnimplementedError()),
      );
      addTearDown(container.dispose);
      return container;
    }

    expect(open().read(crossTabProvider), same(open().read(crossTabProvider)));
  });
}
