// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone mark follows the live presence frames: shown only while every
/// connected socket is a phone, dropped when a desktop joins or they leave.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/presence_devices.dart';

void main() {
  test('a member is mobile-only only while every socket is a phone', () async {
    final events = StreamController<api.ServerEvent>.broadcast(sync: true);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(() async {
      container.dispose();
      await events.close();
    });
    container.read(presenceControllerProvider);
    final mobileOnly = container.listen(
      memberMobileOnlyProvider('u1'),
      (_, _) {},
    );
    addTearDown(mobileOnly.close);

    void tell(api.PresenceState status, Set<api.PresenceDevice> devices) =>
        events.add(
          api.PresenceChanged(userId: 'u1', status: status, devices: devices),
        );

    expect(mobileOnly.read(), isFalse);
    tell(api.PresenceState.online, {api.PresenceDevice.mobile});
    expect(mobileOnly.read(), isTrue);
    tell(api.PresenceState.online, {
      api.PresenceDevice.mobile,
      api.PresenceDevice.desktop,
    });
    expect(mobileOnly.read(), isFalse);
    tell(api.PresenceState.online, {
      api.PresenceDevice.mobile,
      api.PresenceDevice.unknown,
    });
    expect(mobileOnly.read(), isFalse);
    tell(api.PresenceState.online, {api.PresenceDevice.mobile});
    expect(mobileOnly.read(), isTrue);
    tell(api.PresenceState.offline, const {});
    expect(mobileOnly.read(), isFalse);
    expect(container.read(presenceDevicesProvider), isEmpty);
  });
}
