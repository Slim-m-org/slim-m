// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A staged attachment must not carry into another channel's send.
///
/// It is already uploaded, server-side, real cost, and unlike the composer's
/// text (see `channel_drafts_test.dart`) nothing restores it later - so a
/// composer reused across a channel switch (see `channel_read_marker.dart`'s
/// doc comment) must drop it rather than risk sending it to the wrong
/// channel by accident.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets(
    'a staged attachment is dropped when the composer moves to another '
    'channel',
    (tester) async {
      usePicker(pickedFile());
      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          channelId: 'c1',
        ),
      );

      await tester.tap(attachButton);
      await tester.pumpAndSettle();
      expect(find.text('holiday.png'), findsOneWidget);

      await tester.pumpWidget(
        composerHarness(
          controller: controller,
          sends: sends,
          platform: TargetPlatform.linux,
          channelId: 'c2',
        ),
      );
      await tester.pump();

      expect(
        find.text('holiday.png'),
        findsNothing,
        reason:
            'an attachment staged for c1 must not still be sitting in the '
            'composer once it has moved on to c2',
      );
    },
  );

  testWidgets('a composer that stays on the same channel keeps what it '
      'staged', (tester) async {
    usePicker(pickedFile());
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        channelId: 'c1',
      ),
    );

    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    expect(find.text('holiday.png'), findsOneWidget);

    // An unrelated rebuild at the same channel id must not clear anything.
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.linux,
        channelId: 'c1',
      ),
    );
    await tester.pump();

    expect(find.text('holiday.png'), findsOneWidget);
  });
}
