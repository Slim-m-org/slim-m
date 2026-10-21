// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Signing out never left a call ringing.
///
/// `DmCallRingController.clear()` used to be reachable only from
/// `SyncController.start()`, so a sign-out while a call was ringing left
/// `incoming` set for the rest of the process's life. `NotificationSound
/// Controller` stops the looping ring tone only on the transition of
/// `incoming` to null, so the tone kept looping on an account no longer
/// signed in.
///
/// Desktop makes it reachable rather than theoretical: the incoming-call
/// surface there is a floating card that deliberately leaves the rest of the
/// window interactive, so Settings and Sign Out are one click away mid-ring.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_app/src/features/voice/providers/dm_call_ring_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

void main() {
  test(
    'signing out clears an incoming ring, so its tone cannot loop on',
    () async {
      final session = api.SessionStore(tokens: _tokens);
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(session),
          syncControllerProvider.overrideWith(NoopSyncController.new),
          // Sign-out clears the local store; that failure is already swallowed.
          storeProvider.overrideWith((ref) async => throw StateError('n/a')),
        ],
      );
      addTearDown(container.dispose);

      container.read(syncControllerProvider.notifier);
      final ring = container.read(dmCallRingControllerProvider.notifier);
      ring.state = const DmCallRingState(
        incoming: IncomingDmCallRing(
          channelId: 'dm-1',
          ringId: 'ring-1',
          callerId: 'user-2',
        ),
      );
      expect(
        container.read(dmCallRingControllerProvider).incoming,
        isNotNull,
        reason: 'sanity: really ringing before the sign-out',
      );
      container.read(presenceControllerProvider.notifier).state = const {
        'user-2': api.PresenceState.online,
      };

      session.clear();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(presenceControllerProvider),
        isEmpty,
        reason:
            'presence cached under the previous account must not survive into '
            'the next one on a shared device',
      );
      expect(
        container.read(dmCallRingControllerProvider).incoming,
        isNull,
        reason:
            'a ring surviving sign-out keeps NotificationSoundController '
            'looping the tone forever, since it stops only when incoming goes null',
      );
    },
  );
}
