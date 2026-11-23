// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A group DM's long default name truncates on one line in the phone app bar
/// instead of wrapping to two lines that crowd a 56dp bar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _name = 'Person One, Person Two, Person Three and Person Four';

void main() {
  testWidgets('a long group name stays on one line at 390', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const channel = Channel(
      id: 'c1',
      name: _name,
      kind: 'dm',
      createdAt: 0,
      position: 0,
      cursor: 0,
      lastReadSeq: 0,
      mentionedSeq: 0,
      slowModeSeconds: 0,
      joinMuted: false,
      isPersonalSpace: false,
      dmMemberIds: 'self,u1,u2,u3,u4',
    );
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore()),
        liveEventsProvider.overrideWithValue(const Stream.empty()),
        channelByIdProvider.overrideWith((ref, id) => Stream.value(channel)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            appBar: CompactChannelAppBar(channelId: 'c1', onBack: () {}),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    const style = AppText.body;
    final oneLine = style.fontSize! * (style.height ?? 1.2);
    expect(
      tester.getSize(find.text(_name)).height,
      lessThanOrEqualTo(oneLine + 1),
    );
  });
}
