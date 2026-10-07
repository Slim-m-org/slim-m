// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A phone shows a voice channel's whole settings screen at once: one General
/// card holds the name, description, slow mode and join muted (owner backlog
/// 215 read three cards as one list of general settings).
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_app/src/screens/channel_settings_screen.dart';
import 'package:slimm_app/src/widgets/settings_section_header.dart';

import 'channel_management_harness.dart';
import 'ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a voice channel fits one 390x844 screen in one General card', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      RepaintBoundary(
        key: snapshotBoundary,
        child: harness(
          ChannelSettingsScreen(
            args: ChannelSettingsRouteArgs(
              channel: channel('c1', 'movie-room', kind: 'voice'),
              wasOpen: false,
            ),
          ),
          handler: (request) => http.Response(
            request.url.path.contains('/voice') ? '{"participants": []}' : '{}',
            200,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await writeSnapshot(tester, 'channel-settings-voice-phone');

    expect(
      tester.getBottomLeft(find.text('Delete channel')).dy,
      lessThanOrEqualTo(844),
      reason: 'everything, the danger zone included, is on the first screen',
    );
    final generalCard = find.ancestor(
      of: find.bySemanticsLabel('Channel name'),
      matching: find.byType(SettingsSectionCard),
    );
    for (final row in ['Slow mode', 'Join muted']) {
      expect(
        find.descendant(of: generalCard, matching: find.text(row)),
        findsOneWidget,
        reason: '$row sits in the General card',
      );
    }
  });
}
