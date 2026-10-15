// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call screen's header facts and the alone-in-a-call state, from
/// decision 0047 points 9 and 10.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';

import 'support/call_header_fixture.dart';

final members = [
  callProfile('me', 'Me'),
  callProfile('alice', 'Alice'),
  callProfile('nadia', 'Nadia'),
  callProfile('kiki', 'Kiki'),
  callProfile('omar', 'Omar'),
  callProfile('bot', 'Helper', bot: true),
];

void main() {
  testWidgets('the header reads channel, then count, then the timer', (
    tester,
  ) async {
    final call = await joinCall(
      tester,
      width: 1000,
      members: members,
      online: <String>{},
    );
    await call.emit([callMe, callAlice]);

    final channel = tester.getRect(find.text('test-voice'));
    final count = tester.getRect(find.text('2 in call'));
    final timer = tester.getRect(find.byType(CallDuration));
    expect(channel.right, lessThan(count.left));
    expect(count.right, lessThan(timer.left));
    expect((channel.center.dy - count.center.dy).abs(), lessThan(6));

    for (final finder in [find.text('2 in call'), find.byType(CallDuration)]) {
      final style = finder.evaluate().first.widget;
      final resolved = style is Text
          ? style.style!
          : tester
                .widget<Text>(
                  find.descendant(of: finder, matching: find.byType(Text)),
                )
                .style!;
      expect(
        resolved.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
      expect(resolved.fontFamily, AppFonts.mono);
      expect(resolved.fontSize, AppText.micro.fontSize);
    }

    await call.leave();
  });

  testWidgets('alone: one normal tile with its label inside, and no list of '
      'who is online', (tester) async {
    final call = await joinCall(
      tester,
      width: 1400,
      members: members,
      online: {'nadia', 'kiki', 'bot'},
    );
    await call.emit([callMe]);

    final tile = tester.getRect(find.byType(CallParticipantTile));
    expect(tile.size, const Size(320, 200));
    final label = tester.getRect(find.text('Me'));
    expect(tile.contains(label.topLeft), isTrue);
    expect(tile.contains(label.bottomRight), isTrue);

    expect(
      find.textContaining(' online'),
      findsNothing,
      reason: 'the owner does not want to be told who is online while alone',
    );

    await call.leave();
  });

  testWidgets('a DM names nobody', (tester) async {
    final call = await joinCall(
      tester,
      width: 1400,
      members: members,
      online: {'nadia'},
      isDm: true,
    );
    await call.emit([callMe]);

    expect(find.byType(CallParticipantTile), findsOneWidget);
    expect(find.textContaining(' online'), findsNothing);

    await call.leave();
  });

  testWidgets('alone on a phone, the tile fits without overflow', (
    tester,
  ) async {
    final many = [
      callProfile('me', 'Me'),
      for (var i = 0; i < 12; i++)
        callProfile('u$i', 'A very long display name number $i'),
    ];
    final call = await joinCall(
      tester,
      width: 360,
      members: many,
      online: {for (var i = 0; i < 12; i++) 'u$i'},
    );
    await call.emit([callMe]);

    expect(tester.takeException(), isNull);
    final tile = tester.getRect(find.byType(CallParticipantTile));
    expect(tile.width, lessThanOrEqualTo(360 - 2 * AppSpacing.s16));

    await call.leave();
  });

  testWidgets('a joiner adds a tile and keeps the local one mounted', (
    tester,
  ) async {
    final call = await joinCall(
      tester,
      width: 1400,
      members: members,
      online: {'alice', 'nadia'},
    );
    await call.emit([callMe]);
    final before = tester.element(
      find.widgetWithText(CallParticipantTile, 'Me', skipOffstage: false),
    );

    await call.emit([callMe, callAlice]);

    expect(find.byType(CallParticipantTile), findsNWidgets(2));
    expect(find.textContaining(' online'), findsNothing);
    final after = tester.element(
      find.byWidgetPredicate(
        (w) => w is CallParticipantTile && w.participant.isLocal,
      ),
    );
    expect(identical(before, after), isTrue);
    final tiles = tester.getRect(find.byType(CallParticipantTile).first);
    final second = tester.getRect(find.byType(CallParticipantTile).last);
    expect(second.left, greaterThan(tiles.left));

    await call.leave();
  });
}
