// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The follow panel on a phone with many others in the call.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_follow_controls.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_view_relay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  testWidgets('12 others on a phone keep Bring everyone to me on screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final relay = CanvasViewRelay(
      board: const Rect.fromLTWH(0, 0, 1000, 1000),
      send: (_, {required summon, tile}) {},
      showView: (_) {},
      isBlocked: (_) => false,
      selfId: () => 'me',
    );
    addTearDown(relay.following.dispose);
    final cursors = CanvasCursors();
    addTearDown(cursors.dispose);
    final others = [
      for (var i = 0; i < 12; i++)
        VoiceParticipant(
          identity: 'user-${i.toString().padLeft(2, '0')}',
          name: 'Person $i',
          isSpeaking: false,
          isMuted: false,
          isLocal: false,
          isScreenSharing: false,
        ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Stack(
              children: [
                CanvasFollowControls(
                  relay: relay,
                  cursors: cursors,
                  participants: others,
                  selfId: 'me',
                  onBringEveryone: () {},
                ),
              ],
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull, reason: 'RenderFlex overflow');
    final bring = find.bySemanticsLabel('Bring everyone to me');
    expect(bring, findsOneWidget);
    expect(tester.getRect(bring).right, lessThanOrEqualTo(390));
  });
}
