// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone a DM's app bar showed a `#` before the person's name, while the
/// wide header showed their avatar and presence. Both now draw the same glyph
/// from one widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/presence_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_kind_icon.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/widgets/user_avatar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

Channel _channel(String kind, {String? peer}) => Channel(
  id: 'c1',
  name: 'Priya',
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  dmParticipantId: peer,
);

Future<ProviderContainer> _pump(WidgetTester tester, Channel channel) async {
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
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          appBar: CompactChannelAppBar(channelId: 'c1', onBack: () {}),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return container;
}

void main() {
  testWidgets('a DM names the person with their avatar and presence', (
    tester,
  ) async {
    final container = await _pump(tester, _channel('dm', peer: 'user-priya'));
    container.read(presenceControllerProvider.notifier).state = const {
      'user-priya': api.PresenceState.away,
    };
    await tester.pump();

    expect(find.byType(ChannelKindIcon), findsNothing);
    final avatar = tester.widget<AppAvatar>(find.byType(AppAvatar));
    expect(avatar.status, AppPresence.away);
    expect(find.byType(UserAvatar), findsOneWidget);
  });

  testWidgets('a text channel keeps its kind icon', (tester) async {
    await _pump(tester, _channel('text'));

    expect(find.byType(ChannelKindIcon), findsOneWidget);
    expect(find.byType(UserAvatar), findsNothing);
  });
}
