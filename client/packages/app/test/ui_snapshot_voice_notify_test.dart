// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The voice notice banner and the voice channel's call notification choices, at desktop and
/// phone width. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/row_menu_notifications.dart';
import 'package:slimm_app/src/features/voice/providers/voice_notice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_notice_banner_host.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/fake_api.dart';
import 'ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  for (final (label, size) in [
    ('desktop', const Size(1440, 900)),
    ('phone', const Size(390, 844)),
  ]) {
    testWidgets('voice-notify-$label', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWithValue(
            api.SessionStore(
              tokens: const api.TokenPair(
                userId: 'self',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 0,
              ),
            ),
          ),
          liveEventsProvider.overrideWithValue(const Stream.empty()),
          mockApiOverride((_) async => throw UnimplementedError()),
        ],
      );
      addTearDown(container.dispose);
      container
          .read(voiceNoticeProvider.notifier)
          .state = const VoiceNoticeItem(
        channelId: 'lounge',
        text: 'Ada started a call in #lounge',
      );
      const tokens = AppTokens.light;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, tokens),
            home: Scaffold(
              body: RepaintBoundary(
                key: snapshotBoundary,
                child: ColoredBox(
                  color: tokens.surfaceBase,
                  child: VoiceNoticeBannerHost(
                    child: Builder(
                      builder: (context) => Align(
                        alignment: Alignment.topLeft,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: AppMenu(
                            width: 280,
                            children: [
                              ...voiceNotificationMenuItems(
                                context,
                                container,
                                'lounge',
                                () {},
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await writeSnapshot(tester, 'voice-notify-$label');
      expect(tester.takeException(), isNull);
    });
  }
}
