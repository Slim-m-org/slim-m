// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The animated call roster: a joiner pops in, a leaver plays out in place
/// before the wrap reflows, and reduce motion skips both.
///
/// Driven through [AnimatedRosterWrap] directly with plain value
/// participants, so none of this needs a `VoiceController` - the grid in
/// `call_stage_layout.dart` is a thin caller of exactly this widget.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_roster_motion.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/reduced_motion_harness.dart';

VoiceParticipant _p(String id, {bool cameraOn = false}) => VoiceParticipant(
  identity: id,
  name: 'name-$id',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
  isCameraOn: cameraOn,
);

Future<void> _pump(
  WidgetTester tester,
  List<VoiceParticipant> participants, {
  bool reduceMotion = false,
}) => tester.pumpWidget(
  MediaQuery(
    data: reducedMotionData(disableAnimations: reduceMotion),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: AnimatedRosterWrap(
          participants: participants,
          spacing: 8,
          tileFor: (context, p) => SizedBox(
            width: 60,
            height: 40,
            child: Text('${p.name}:${p.isCameraOn}'),
          ),
        ),
      ),
    ),
  ),
);

double _tileOpacity(WidgetTester tester, Key key) => tester
    .widget<Opacity>(
      find.descendant(of: find.byKey(key), matching: find.byType(Opacity)),
    )
    .opacity;

void main() {
  testWidgets('a joiner pops in while settled tiles hold still', (
    tester,
  ) async {
    await _pump(tester, [_p('a')]);
    await tester.pumpAndSettle();

    await _pump(tester, [_p('a'), _p('b')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final joining = _tileOpacity(tester, const ValueKey('tile-b'));
    expect(joining, greaterThan(0));
    expect(joining, lessThan(1));
    expect(_tileOpacity(tester, const ValueKey('tile-a')), 1);

    await tester.pumpAndSettle();
    expect(_tileOpacity(tester, const ValueKey('tile-b')), 1);
  });

  testWidgets('a leaver plays out inert in place, then the wrap reflows', (
    tester,
  ) async {
    await _pump(tester, [_p('a'), _p('b'), _p('c')]);
    await tester.pumpAndSettle();
    final cBefore = tester.getTopLeft(find.text('name-c:false'));

    await _pump(tester, [_p('a'), _p('c')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    // Mid-exit the tile is still mounted, inert, in its old slot.
    final exitTile = find.byKey(const ValueKey('tile-exit-b'));
    expect(exitTile, findsOneWidget);
    expect(
      tester
          .widget<IgnorePointer>(
            find.descendant(of: exitTile, matching: find.byType(IgnorePointer)),
          )
          .ignoring,
      isTrue,
    );
    expect(tester.getTopLeft(find.text('name-c:false')), cBefore);

    await tester.pumpAndSettle();
    expect(find.text('name-b:false'), findsNothing);
    expect(
      tester.getTopLeft(find.text('name-c:false')).dx,
      lessThan(cBefore.dx),
    );
  });

  testWidgets('a leaver exits as a stilled tile, never a live camera', (
    tester,
  ) async {
    await _pump(tester, [_p('a'), _p('b', cameraOn: true)]);
    await tester.pumpAndSettle();
    expect(find.text('name-b:true'), findsOneWidget);

    await _pump(tester, [_p('a')]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.text('name-b:true'), findsNothing);
    expect(find.text('name-b:false'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('reduce motion removes a leaver at once', (tester) async {
    await _pump(tester, [_p('a'), _p('b')], reduceMotion: true);
    await tester.pump();

    await _pump(tester, [_p('a')], reduceMotion: true);
    await tester.pump();
    expect(find.text('name-b:false'), findsNothing);
    expect(find.byKey(const ValueKey('tile-exit-b')), findsNothing);
  });
}
