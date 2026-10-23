// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Desktop-vs-mobile rule 6 and 1: a short window (a landscape phone) hands
/// the header's height to the board, since the dock repeats its controls.
/// At 844x390 the header and the dock left the shared area about 290 px.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_bar.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pane.dart';
import 'package:slimm_app/src/features/members/widgets/member_list_toggle.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/floating_dock_card.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

class _Voice extends VoiceController {
  _Voice(super.ref) : super(session: FakeSession()) {
    state = const VoiceState(
      channelId: 'c1',
      state: VoiceSessionState.connected,
      participants: [
        VoiceParticipant(
          identity: 'user-ada',
          name: 'Ada',
          isSpeaking: false,
          isMuted: false,
          isLocal: false,
          isScreenSharing: false,
        ),
      ],
    );
  }
}

Future<void> _pump(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [voiceControllerProvider.overrideWith(_Voice.new)],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  container.read(canvasOpenProvider.notifier).state = 'c1';
  await pumpCanvasPane(tester, container, board: true, tool: null);
}

/// Where the shared area lands on screen at the opening fit.
Rect _sharedOnScreen(WidgetTester tester) {
  final document = surfaceDocument(tester);
  final origin = tester.getTopLeft(find.byType(CanvasSurface));
  final zoom = document.camera.zoom;
  final view = document.worldView.topLeft;
  return Rect.fromLTRB(
    origin.dx + (canvasSharedArea.left - view.dx) * zoom,
    origin.dy + (canvasSharedArea.top - view.dy) * zoom,
    origin.dx + (canvasSharedArea.right - view.dx) * zoom,
    origin.dy + (canvasSharedArea.bottom - view.dy) * zoom,
  );
}

void main() {
  for (final size in const [Size(844, 390), Size(740, 360)]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()} gives the board '
        'the header height and keeps it clear of the dock', (tester) async {
      await _pump(tester, size);

      expect(find.byType(CanvasBar), findsNothing);
      final shared = _sharedOnScreen(tester);
      expect(shared.top, greaterThanOrEqualTo(0));
      expect(
        shared.height,
        greaterThan(size.height * 0.7),
        reason: 'the board fits the height the dock leaves',
      );
      final dock = tester.getRect(find.byType(FloatingDockCard).first);
      expect(
        shared.bottom - dock.top,
        lessThanOrEqualTo(12),
        reason: 'only the dock margin may overlap the fitted board',
      );
      expect(shared.left, greaterThanOrEqualTo(0));
      expect(shared.right, lessThanOrEqualTo(size.width));
    });
  }

  testWidgets('the member toggle floats in a short window where it fits', (
    tester,
  ) async {
    await _pump(tester, const Size(844, 390));

    final toggle = tester.getRect(find.byType(MemberListToggle));
    expect(toggle.top, greaterThanOrEqualTo(0));
    expect(toggle.right, lessThanOrEqualTo(844));
    final dock = tester.getRect(find.byType(FloatingDockCard).first);
    expect(toggle.overlaps(dock), isFalse);
  });

  for (final size in const [Size(390, 844), Size(1280, 800)]) {
    testWidgets('${size.width.toInt()}x${size.height.toInt()} keeps its '
        'header', (tester) async {
      await _pump(tester, size);

      expect(find.byType(CanvasBar), findsOneWidget);
    });
  }
}
