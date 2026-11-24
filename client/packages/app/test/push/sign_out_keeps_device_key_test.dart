// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The push keypair is device-wide, so signing one account out must not delete
/// the key every other signed-in account is still registered with.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/features/accounts/providers/account_services.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../features/accounts/account_host_harness.dart';
import '../support/fake_api.dart';

class _KeyHoldingPush extends PushController {
  _KeyHoldingPush(super.ref);

  @override
  Future<void> register() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<(AccountHarness, InMemoryKeyStore)> twoAccounts() async {
    final keys = InMemoryKeyStore();
    final harness = AccountHarness(
      keys: keys,
      extraOverrides: [
        pushControllerProvider.overrideWith((ref) => _KeyHoldingPush(ref)),
        mockApiOverride((_) async => http.Response('', 204)),
      ],
    );
    await harness.seed('https://first.example', user: 'u1', active: true);
    await harness.seed('https://second.example', user: 'u2');
    await harness.boot();
    return (harness, keys);
  }

  test('signing out one of two accounts keeps the device push key', () async {
    final (harness, keys) = await twoAccounts();
    addTearDown(harness.dispose);
    await DevicePushKeys(keys).publicKeyBase64();

    final runtime = harness.host.runtimeFor('https://second.example')!;
    await signOutVia(runtime.container.read);

    expect(await keys.read(devicePushKeyHandle), isNotNull);
  });

  test('signing out the last signed-in account deletes the key', () async {
    final (harness, keys) = await twoAccounts();
    addTearDown(harness.dispose);
    await DevicePushKeys(keys).publicKeyBase64();

    for (final r in harness.host.accounts.toList()) {
      r.signedIn = false;
    }
    final runtime = harness.host.runtimeFor('https://second.example')!;
    runtime.signedIn = true;
    await signOutVia(runtime.container.read);

    expect(await keys.read(devicePushKeyHandle), isNull);
  });
}
