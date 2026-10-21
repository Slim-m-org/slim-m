// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call that failed or dropped for good no longer leaves the canvas silent:
/// the reason shows with a way to join again.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

class _Recording extends RecordingVoiceController {
  _Recording(super.ref, VoiceState failed) {
    state = failed;
  }
}

Future<RecordingVoiceController> _pump(
  WidgetTester tester, {
  required VoiceState voice,
}) async {
  late RecordingVoiceController controller;
  final fixture = CanvasPaneFixture();
  final container = fixture.container(
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => controller = _Recording(ref, voice),
      ),
    ],
  );
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('a failed call says why and offers to join again', (
    tester,
  ) async {
    final controller = await _pump(
      tester,
      voice: const VoiceState(
        channelId: 'c1',
        state: VoiceSessionState.failed,
        error: 'The connection to the call dropped.',
      ),
    );

    expect(find.text('The connection to the call dropped.'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(AppErrorState),
        matching: find.text('Retry'),
      ),
    );
    await tester.pump();

    expect(controller.joins, ['c1']);
  });

  testWidgets('a call that works shows no failure', (tester) async {
    await _pump(
      tester,
      voice: const VoiceState(
        channelId: 'c1',
        state: VoiceSessionState.connected,
      ),
    );

    expect(find.byType(AppErrorState), findsNothing);
  });

  testWidgets('a failure in some other channel is not this canvas\'s', (
    tester,
  ) async {
    await _pump(
      tester,
      voice: const VoiceState(
        channelId: 'elsewhere',
        state: VoiceSessionState.failed,
        error: 'nope',
      ),
    );

    expect(find.byType(AppErrorState), findsNothing);
  });
}
