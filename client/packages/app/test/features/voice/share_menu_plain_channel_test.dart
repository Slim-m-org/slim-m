// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// "Viewers can draw" is in the share menu of a plain voice channel's dock, not only a canvas lounge's.
/// Set SLIMM_SHARE_SHOTS to a directory to also write the open menu as a PNG.
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_overlay_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_call_controls_harness.dart';

const _sharing = VoiceFlags(
  state: VoiceSessionState.connected,
  screenSharing: true,
);

Future<void> _shot(WidgetTester tester, String name) async {
  final dir = Platform.environment['SLIMM_SHARE_SHOTS'];
  if (dir == null) return;
  final layer = tester.binding.renderViews.first.debugLayer! as OffsetLayer;
  await tester.runAsync(() async {
    final image = await layer.toImage(
      tester.binding.renderViews.first.paintBounds,
      pixelRatio: 2,
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final canvas in [null, 'channel']) {
    testWidgets(
      'the share menu offers drawing in a ${canvas == null ? 'plain voice channel' : 'canvas lounge'}',
      (tester) async {
        tester.view.physicalSize = const Size(1400, 880);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await pumpVoiceCallDock(
          tester,
          _sharing,
          canvasChannelId: canvas,
          width: 900,
          scoped: false,
          extraOverrides: [
            screenOverlaySupportedProvider.overrideWithValue(true),
          ],
        );
        await tester.tap(find.byTooltip('Screen share options'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(find.text('Viewers can draw'), findsOneWidget);
        await _shot(tester, 'share-menu-${canvas ?? 'plain'}-desktop');
      },
    );
  }

  testWidgets('the share menu offers drawing where no overlay can be hosted', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 880);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpVoiceCallDock(
      tester,
      _sharing,
      width: 900,
      scoped: false,
      extraOverrides: [screenOverlaySupportedProvider.overrideWithValue(false)],
    );
    await tester.tap(find.byTooltip('Screen share options'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Viewers can draw'), findsOneWidget);
  });
}
