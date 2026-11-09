// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The strip keeps its scroll when the call stage is swapped out for the
/// canvas and back, instead of snapping to the first tile.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/call_filmstrip.dart';
import 'package:slimm_app/src/features/voice/widgets/call_participant_tiles.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _stripKey = ValueKey('strip');

Widget _app({required bool lounge, String channelId = 'c1'}) => ProviderScope(
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: lounge
          ? SizedBox(
              width: 600,
              height: 128,
              child: CallFilmstrip(
                key: _stripKey,
                channelId: channelId,
                leading: const [],
                leadingItemWidth: 199,
                participants: [
                  for (var i = 0; i < 12; i++)
                    VoiceParticipant(
                      identity: 'p$i',
                      name: 'p$i',
                      isSpeaking: false,
                      isMuted: false,
                      isLocal: false,
                      isScreenSharing: false,
                    ),
                ],
                tileBuilder: (context, p) => SizedBox(
                  key: ValueKey('tile-${p.identity}'),
                  width: kCallTileMinWidth,
                  height: 90,
                ),
              ),
            )
          : const SizedBox(key: ValueKey('canvas')),
    ),
  ),
);

double _offset(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.descendant(
        of: find.byKey(_stripKey),
        matching: find.byWidgetPredicate((w) => w is Scrollable),
      ),
    )
    .position
    .pixels;

void main() {
  testWidgets('the filmstrip returns to where it was scrolled', (tester) async {
    await tester.pumpWidget(_app(lounge: true));
    await tester.pump(const Duration(seconds: 1));

    await tester.drag(find.byKey(_stripKey), const Offset(-300, 0));
    await tester.pump(const Duration(seconds: 1));
    final scrolled = _offset(tester);
    expect(scrolled, greaterThan(100));

    await tester.pumpWidget(_app(lounge: false));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_app(lounge: true));
    await tester.pump(const Duration(seconds: 1));

    expect(_offset(tester), scrolled);
  });

  testWidgets('another call does not inherit the strip offset', (tester) async {
    await tester.pumpWidget(_app(lounge: true));
    await tester.pump(const Duration(seconds: 1));
    await tester.drag(find.byKey(_stripKey), const Offset(-300, 0));
    await tester.pump(const Duration(seconds: 1));

    await tester.pumpWidget(_app(lounge: false));
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(_app(lounge: true, channelId: 'c2'));
    await tester.pump(const Duration(seconds: 1));

    expect(_offset(tester), 0);
  });
}
