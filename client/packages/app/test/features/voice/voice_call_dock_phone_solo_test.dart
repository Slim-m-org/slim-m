// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A solo call on a phone: the canvas toggle and the music rows sit in the More
/// menu, whose button is in the dock (above the call row when the row is too
/// narrow), not inside the mic menu. Width decides (desktop-vs-mobile.md, the
/// one rule).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/widgets/call_dock_button.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _me = VoiceParticipant(
  identity: 'me',
  name: 'me',
  isSpeaking: false,
  isMuted: false,
  isLocal: true,
  isScreenSharing: false,
);

void main() {
  for (final size in const [Size(390, 844), Size(360, 780)]) {
    testWidgets(
      'solo call at ${size.width.toInt()}: canvas and music are in More',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await pumpVoiceCallDock(
          tester,
          const VoiceFlags(state: VoiceSessionState.connected),
          canvasChannelId: 'c1',
          width: size.width - 2 * AppSpacing.s16,
          touch: true,
          extraOverrides: [
            voiceParticipantsProvider.overrideWithValue([_me]),
          ],
        );

        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('Open canvas'), findsNothing);
        expect(
          tester
              .widget<FloatingDockCard>(find.bySubtype<FloatingDockCard>())
              .rows,
          hasLength(size.width == 390 ? 1 : 2),
          reason:
              'More fits beside the controls at 390, takes a row above at 360',
        );

        final card = tester.getRect(find.bySubtype<FloatingDockCard>());
        final buttons = find.bySubtype<CallDockButton>();
        expect(buttons, findsNWidgets(6));
        for (final e in buttons.evaluate()) {
          final r = tester.getRect(find.byElementPredicate((x) => x == e));
          expect(r.width, greaterThanOrEqualTo(AppSizes.rowTouch));
          expect(r.height, greaterThanOrEqualTo(AppSizes.rowTouch));
          expect(
            card.contains(r.topLeft) && card.contains(r.bottomRight),
            isTrue,
          );
        }

        await tester.pump(const Duration(milliseconds: 400));
        await tester.tap(find.bySemanticsLabel('More'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('Open canvas'), findsOneWidget);
        expect(find.text('Play music'), findsOneWidget);
      },
    );
  }
}
