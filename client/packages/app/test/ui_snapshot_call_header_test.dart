// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call screen's header and alone state at desktop and phone width. PNGs
/// are written only under SLIMM_UI_SNAPSHOTS=1; otherwise this asserts the
/// screen lays out without overflow.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart' show kCompactWidth;
import 'package:slimm_app/src/screens/canvas/canvas_bar.dart';
import 'package:slimm_app/src/screens/voice_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/widgets/call_participant_tiles.dart';

import 'support/call_header_fixture.dart';
import 'ui_snapshot_support.dart';

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  final members = [
    callProfile('me', 'Me'),
    callProfile('alice', 'Alice'),
    callProfile('nadia', 'Nadia'),
    callProfile('kiki', 'Kiki'),
  ];
  const sizes = {'phone': (390.0, 844.0), 'desktop': (1400.0, 900.0)};
  for (final theme in const ['dark', 'light']) {
    for (final entry in sizes.entries) {
      for (final alone in const [true, false]) {
        final state = alone ? 'alone' : 'two';
        testWidgets('call $state at ${entry.key} ($theme)', (tester) async {
          final call = await joinCall(
            tester,
            width: entry.value.$1,
            height: entry.value.$2,
            members: members,
            online: {'nadia', 'kiki'},
            dark: theme == 'dark',
            withCanvasBar: true,
          );
          await call.emit(alone ? [callMe] : [callMe, callAlice]);
          expect(
            find.byType(CallParticipantTile),
            findsNWidgets(alone ? 1 : 2),
          );
          if (entry.value.$1 >= kCompactWidth) {
            expect(
              tester.getTopLeft(find.byType(CanvasBar)).dx,
              greaterThanOrEqualTo(
                tester.getTopRight(find.byType(VoiceScreen)).dx,
              ),
              reason: 'the canvas pane sits beside the stage, never above it',
            );
          }
          await writeSnapshot(tester, 'call-$state-${entry.key}-$theme');
          expect(tester.takeException(), isNull);
          await call.leave();
        });
      }
    }
  }
}
