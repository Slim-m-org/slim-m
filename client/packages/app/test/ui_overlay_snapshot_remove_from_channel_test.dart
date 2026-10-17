// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member card opened from a channel's roster by someone who manages that
/// channel: the "Remove from #channel" row, at desktop popover and phone sheet
/// widths. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/features/channels/providers/channel_by_id_provider.dart';
import 'package:slimm_app/src/features/channels/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_data/data.dart' as data;
import 'package:slimm_design_system/design_system.dart';

import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _channelId = 'channel-secret';

const _other = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'Maya',
  createdAt: 0,
);

const _channel = data.Channel(
  id: _channelId,
  name: 'secret',
  kind: 'text',
  createdAt: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  isPersonalSpace: false,
  joinMuted: false,
  position: 0,
  slowModeSeconds: 0,
);

Future<void> _capture(WidgetTester tester, double width, String name) async {
  tester.view.physicalSize = Size(width + 40, 880);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        myPermissionsProvider.overrideWithValue(0),
        membersProvider.overrideWith((ref) async => [_other]),
        channelByIdProvider.overrideWith((ref, id) => Stream.value(_channel)),
        myChannelPermissionsProvider.overrideWith(
          (ref, id) => Perm.manageRoles,
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: RepaintBoundary(
                key: snapshotBoundary,
                child: MemberProfileBody(
                  profile: _other,
                  compact: width < 400,
                  channelId: _channelId,
                  onDone: () {},
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  expect(find.text('Remove from #secret'), findsOneWidget);
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('desktop popover width', (tester) async {
    await _capture(tester, 320, 'member-popover-remove-from-channel-desktop');
  });

  testWidgets('phone sheet width', (tester) async {
    await _capture(tester, 390, 'member-popover-remove-from-channel-phone');
  });
}
