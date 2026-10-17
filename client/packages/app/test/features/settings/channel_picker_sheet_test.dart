// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel picker listed a DM with a hash icon, as if it were a channel
/// that could carry permission overwrites or a webhook.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/overwrite_target_picker_sheets.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';

Channel _channel(String name, String kind) => Channel(
  id: 'c-$name',
  name: name,
  kind: kind,
  createdAt: 0,
  position: 0,
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
);

void main() {
  testWidgets('lists text and voice channels and no direct messages', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: ChannelPickerSheet(
            channels: [
              _channel('general', 'text'),
              _channel('Bob', 'dm'),
              _channel('lounge', 'voice'),
            ],
          ),
        ),
      ),
    );

    expect(find.text('general'), findsOneWidget);
    expect(find.text('lounge'), findsOneWidget);
    expect(find.text('Bob'), findsNothing);
  });
}
