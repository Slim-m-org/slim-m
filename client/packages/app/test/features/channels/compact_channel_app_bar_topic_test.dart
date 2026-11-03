// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone app bar's name and topic fit inside its 48 dp toolbar: the topic
/// used to take the bar's whole height and push the name out of the top.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  testWidgets('name and topic both sit inside the toolbar', (tester) async {
    tester.view.physicalSize = const Size(390, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore()),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
          channelByIdProvider('c1').overrideWith(
            (ref) => Stream.value(
              const Channel(
                id: 'c1',
                name: 'general',
                kind: 'text',
                createdAt: 0,
                position: 0,
                cursor: 0,
                lastReadSeq: 0,
                mentionedSeq: 0,
                slowModeSeconds: 0,
                joinMuted: false,
                isPersonalSpace: false,
                topic: 'General chat for the whole Space',
              ),
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            appBar: CompactChannelAppBar(channelId: 'c1', onBack: () {}),
            body: const SizedBox.expand(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    final bar = tester.getRect(find.byType(AppBar));
    final name = tester.getRect(find.text('general'));
    final topic = tester.getRect(find.text('General chat for the whole Space'));
    expect(name.top, greaterThanOrEqualTo(bar.top));
    expect(topic.bottom, lessThanOrEqualTo(bar.bottom));
    expect(topic.top, greaterThanOrEqualTo(name.bottom - 1));
  });
}
