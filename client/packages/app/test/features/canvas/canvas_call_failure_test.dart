// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A call that failed or dropped for good no longer leaves the canvas silent:
/// the reason shows with a way to join again, and never over the board's own.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_engine.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';
import 'package:slimm_app/src/widgets/status_pill.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import '../voice/voice_controller_harness.dart';
import 'canvas_pane_harness.dart';

const _dropped = 'The connection to the call dropped.';
const _removed = 'You were removed from the call.';

class _Recording extends RecordingVoiceController {
  _Recording(super.ref, VoiceState failed) {
    state = failed;
  }
}

Future<({RecordingVoiceController controller, CanvasEngine engine})> _pump(
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
  return (
    controller: controller,
    engine: container.read(canvasEngineProvider('c1').notifier),
  );
}

VoiceState _failed(String error, {bool retryable = true}) => VoiceState(
  channelId: 'c1',
  state: VoiceSessionState.failed,
  error: error,
  retryable: retryable,
);

void main() {
  testWidgets('a failed call says why and offers to join again', (
    tester,
  ) async {
    final (:controller, engine: _) = await _pump(
      tester,
      voice: _failed(_dropped),
    );

    expect(find.text(_dropped), findsOneWidget);

    await tester.tap(find.text('Rejoin'));
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

    expect(find.byType(StatusPill), findsNothing);
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

    expect(find.byType(StatusPill), findsNothing);
  });

  testWidgets('the board\'s own failures are never hidden behind the call\'s', (
    tester,
  ) async {
    final (controller: _, :engine) = await _pump(
      tester,
      voice: _failed(_dropped),
    );
    final refused = canvasDrawForbiddenMessage(null);
    engine.reportError(refused);
    surfaceDocument(tester).setUnsaved('stroke-1', unsaved: true);
    await pumpFrames(tester, frames: 20);

    expect(find.text(refused), findsOneWidget);
    expect(find.text(_dropped), findsNothing);

    await tester.tap(find.byKey(StatusPill.dismissKey));
    await pumpFrames(tester, frames: 20);

    expect(find.textContaining('not saved'), findsOneWidget);
    expect(find.text(_dropped), findsNothing);

    surfaceDocument(tester).setUnsaved('stroke-1', unsaved: false);
    await pumpFrames(tester, frames: 20);

    expect(find.text(_dropped), findsOneWidget);
  });

  testWidgets('a failure that cannot be retried can be closed', (tester) async {
    final (:controller, engine: _) = await _pump(
      tester,
      voice: _failed(_removed, retryable: false),
    );

    expect(find.text('Rejoin'), findsNothing);
    await tester.tap(find.byKey(StatusPill.dismissKey));
    await pumpFrames(tester, frames: 20);

    expect(find.text(_removed), findsNothing);

    controller.replace(
      const VoiceState(channelId: 'c1', state: VoiceSessionState.connecting),
    );
    await pumpFrames(tester);
    controller.replace(_failed(_removed, retryable: false));
    await pumpFrames(tester, frames: 20);

    expect(find.text(_removed), findsOneWidget);
  });
}
