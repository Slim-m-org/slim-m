// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call stage's colour stays on the stage: the chat pane docked beside it
/// has no surface of its own to hide a glow that spills over.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/features/voice/providers/lounge_canvas_glow.dart';
import 'package:slimm_app/src/features/voice/widgets/lounge_backdrop.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

const _stage = 500.0;
const _probeKey = Key('pane_probe');

VoiceParticipant _p(String id) => VoiceParticipant(
  identity: id,
  name: id,
  isSpeaking: true,
  isMuted: false,
  isLocal: false,
  isScreenSharing: false,
);

api.UserProfile _profile(String id, int colour) => api.UserProfile(
  id: id,
  username: id,
  displayName: id,
  createdAt: 0,
  profileColor: colour,
);

Future<ui.Image> _solid() async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    const Rect.fromLTWH(0, 0, 4, 4),
    Paint()..color = const Color(0xFFE86A5C),
  );
  return recorder.endRecording().toImage(4, 4);
}

Future<void> _expectPaneUntouched(WidgetTester tester, {ui.Image? glow}) async {
  tester.view.physicalSize = const Size(2 * _stage, 400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  const boundary = Key('bleed_boundary');
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        loungeCanvasGlowProvider('c1').overrideWith((ref) async => glow),
        for (var i = 0; i < 4; i++)
          userProfileProvider(
            'u$i',
          ).overrideWith((ref) async => _profile('u$i', i)),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: RepaintBoundary(
          key: boundary,
          child: ColoredBox(
            color: const Color(0xFF000000),
            child: Row(
              children: [
                SizedBox(
                  width: _stage,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: LoungeBackdrop(
                          channelId: 'c1',
                          participants: [for (var i = 0; i < 4; i++) _p('u$i')],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(key: _probeKey, width: _stage),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();

  final render = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(boundary),
  );
  final painted = await tester.runAsync(() async {
    final image = await render.toImage();
    final bytes = (await image.toByteData())!;
    var lit = 0;
    for (var y = 0; y < image.height; y += 8) {
      for (var x = _stage.toInt() + 1; x < image.width; x += 8) {
        final i = (y * image.width + x) * 4;
        if (bytes.getUint8(i) + bytes.getUint8(i + 1) + bytes.getUint8(i + 2) >
            0)
          lit++;
      }
    }
    return lit;
  });
  expect(painted, 0, reason: 'the stage painted into the pane beside it');
}

void main() {
  testWidgets('the aurora stays inside the stage', (tester) async {
    await _expectPaneUntouched(tester);
  });

  testWidgets('the canvas glow stays inside the stage', (tester) async {
    final glow = await tester.runAsync(_solid);
    await _expectPaneUntouched(tester, glow: glow);
  });
}
