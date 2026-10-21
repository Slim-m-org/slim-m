// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Hovering a device row in setup must not paint over the group's outline.
library;

import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/first_run/widgets/first_run_device_steps.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/audio_device_section.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../support/fake_mic_preview.dart';
import 'voice_settings_screen_harness.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the outline survives hovering the Test speaker row', (
    tester,
  ) async {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    addTearDown(
      () => FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic,
    );
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const boundary = Key('outline-boundary');
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: wrap(
          const FirstRunVoiceStep(),
          overrides: [
            voiceControllerProvider.overrideWith(
              (ref) => VoiceController(ref, session: FakeSession()),
            ),
            fakeMicPreview(FakeMicSource()),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byKey(speakerTestRowKey)));
    await tester.pumpAndSettle();

    final rowBox = tester.getRect(find.byKey(speakerTestRowKey));
    final tokens = Theme.of(
      tester.element(find.byKey(speakerTestRowKey)),
    ).extension<AppTokens>()!;
    final edge = await tester.runAsync(() async {
      final render = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(boundary),
      );
      final image = await render.toImage();
      final data = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final x = rowBox.left.floor();
      final y = rowBox.center.dy.floor();
      final i = (y * image.width + x) * 4;
      return Color.fromARGB(
        data.getUint8(i + 3),
        data.getUint8(i),
        data.getUint8(i + 1),
        data.getUint8(i + 2),
      );
    });

    expect(edge, isNot(tokens.surfaceRaised));
    await tester.pumpWidget(const SizedBox());
  });
}
