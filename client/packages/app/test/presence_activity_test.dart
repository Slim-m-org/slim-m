// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The activity map follows the live presence frames: set on one carrying an
/// activity, cleared on one without.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/presence_activity.dart';
import 'package:slimm_app/src/features/members/providers/presence_controller.dart';

void main() {
  test('a presence frame sets and then clears a member activity', () async {
    final events = StreamController<api.ServerEvent>.broadcast(sync: true);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(() async {
      container.dispose();
      await events.close();
    });
    container.read(presenceControllerProvider);

    const activity = api.PresenceActivity(
      kind: api.ActivityKind.listening,
      title: 'Song',
      subtitle: 'Artist',
    );
    events.add(
      const api.PresenceChanged(
        userId: 'u1',
        status: api.PresenceState.online,
        activity: activity,
      ),
    );
    expect(container.read(presenceActivityProvider)['u1'], activity);
    expect(describeActivity(activity), 'Listening to Song - Artist');

    events.add(
      const api.PresenceChanged(
        userId: 'u1',
        status: api.PresenceState.offline,
      ),
    );
    expect(container.read(presenceActivityProvider), isEmpty);
  });
}
