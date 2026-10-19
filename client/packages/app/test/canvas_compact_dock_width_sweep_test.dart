// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone canvas dock at 320, 360 and 390dp, alone and with someone else on
/// the call, camera on and off: the call row never overflows its card and
/// every control keeps a 44dp touch target.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_rtc/rtc.dart';

import 'support/canvas_call_dock_fixtures.dart';

const _remote = VoiceParticipant(
  identity: 'bob',
  name: 'Bob',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

const _controls = ['Mute', 'Share a screen', 'Leave call'];

Future<VoiceController> _pump(
  WidgetTester tester,
  double width, {
  required bool alone,
  required bool camera,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final dock = await pumpCanvasCallDock(
    tester,
    withCall: true,
    canvas: buildCanvasDockData(),
    compact: true,
    canFlipCamera: camera,
    width: width,
    callVoice: VoiceFlags(
      state: VoiceSessionState.connected,
      cameraEnabled: camera,
    ),
  );
  await dock.controller!.join('c1');
  dock.session!.emitState(VoiceSessionState.connected);
  dock.session!.emitParticipants(alone ? const [] : const [_remote]);
  await tester.pumpAndSettle();
  return dock.controller!;
}

void main() {
  for (final width in [320.0, 360.0, 390.0]) {
    for (final alone in [true, false]) {
      for (final camera in [false, true]) {
        testWidgets(
          'no overflow at ${width}dp, ${alone ? 'alone' : 'not alone'}, '
          'camera ${camera ? 'on' : 'off'}',
          (tester) async {
            final call = await _pump(
              tester,
              width,
              alone: alone,
              camera: camera,
            );

            expect(tester.takeException(), isNull);
            final card = tester.getRect(find.byType(FloatingDockCard).last);
            for (final label in _controls) {
              final rect = tester.getRect(
                find.bySemanticsLabel(RegExp('^$label')).first,
              );
              expect(
                card.inflate(0.5).contains(rect.topLeft) &&
                    card.inflate(0.5).contains(rect.bottomRight),
                isTrue,
                reason: '$label inside the card',
              );
              expect(rect.shortestSide, greaterThanOrEqualTo(44));
            }
            expect(card.right, lessThanOrEqualTo(width));
            await call.leave();
            await tester.pumpAndSettle();
          },
        );
      }
    }
  }
}
