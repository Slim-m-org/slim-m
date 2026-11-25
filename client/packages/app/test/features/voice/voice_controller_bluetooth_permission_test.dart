// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call asks for the Bluetooth grant before the session starts routing
/// audio, and a denial still joins.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/bluetooth_permission_provider.dart';
import 'package:slimm_platform/platform.dart';

import 'voice_controller_harness.dart';

class _FakeBluetooth extends BluetoothPermissionChannel {
  _FakeBluetooth(this.session, {required this.granted});

  final FakeSession session;
  final bool granted;
  final joinedWhenAsked = <bool?>[];

  @override
  Future<bool> request() async {
    joinedWhenAsked.add(session.joinedAbleToPublish);
    return granted;
  }
}

void main() {
  final harness = VoiceHarness();

  tearDown(harness.dispose);

  for (final granted in [true, false]) {
    test(
      'asks before the session joins and joins when granted is $granted',
      () async {
        final session = FakeSession();
        final bluetooth = _FakeBluetooth(session, granted: granted);
        final controller = harness.controllerWith(
          session,
          voiceApi(),
          extraOverrides: [
            bluetoothPermissionProvider.overrideWithValue(bluetooth),
          ],
        );

        await controller.join('channel-1');

        expect(bluetooth.joinedWhenAsked, [null]);
        expect(session.joinedAbleToPublish, isNotNull);
        expect(controller.state.error, isNull);
      },
    );
  }
}
