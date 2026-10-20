// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Expanding one canvas presence tile asks the pane to focus its feed.
///
/// Covers the affordance and its one gate (a camera showing the avatar
/// fallback has no feed to expand), that expanding reports the tile key
/// instead of opening the voice screen's route over the canvas
/// (`canvas_focused_tile_test.dart` owns what the pane then does), and the
/// subscription half: the focused tile stops being drawn here but every
/// tile stays subscribed.
///
/// The interest assertions read the real reported sets: a fixture of three
/// cameras all inside the viewport is what makes a wrong answer visible.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_layer.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_presence_tile_controls.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/voice/voice_controller_harness.dart';

const _expandLabel = 'Show this tile full screen';

VoiceParticipant _camera(String id, String name, {bool on = true}) =>
    VoiceParticipant(
      identity: id,
      name: name,
      isSpeaking: false,
      isMuted: false,
      isLocal: false,
      isScreenSharing: false,
      isCameraOn: on,
    );

/// Three remote cameras, all on. Three is the point: the narrowed answer has
/// to be provably smaller than the ordinary one.
final _roster = [
  _camera('user-noor', 'Noor'),
  _camera('user-ada', 'Ada'),
  _camera('user-rex', 'Rex'),
];

/// Everything one of these tests drives, plus the interest sets the layer
/// actually reported, in order.
class _Fixture {
  _Fixture(
    this.harness,
    this.session,
    this.document,
    this.interest,
    this.focused,
  );

  final VoiceHarness harness;
  final FakeSession session;
  final CanvasDocument document;
  final List<Set<String>?> interest;
  final ValueNotifier<String?> focused;

  /// Stops the heartbeat `connected` started, from the test body itself: the
  /// pending-timer check runs before `addTearDown`, the trap
  /// `sign_out_leaves_call_test.dart` already documents.
  Future<void> leave() =>
      harness.container.read(voiceControllerProvider.notifier).leave();
}

Future<_Fixture> _seated(
  WidgetTester tester, {
  List<VoiceParticipant>? participants,
}) async {
  final roster = participants ?? _roster;
  final harness = VoiceHarness();
  final session = FakeSession();
  final controller = harness.controllerWith(session, voiceApi());
  final document = CanvasDocument()..setViewport(const Size(1200, 800));
  addTearDown(document.dispose);
  final overrides = CanvasPresenceTileOverrides();
  addTearDown(overrides.dispose);
  final interest = <Set<String>?>[];
  final focused = ValueNotifier<String?>(null);
  addTearDown(focused.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: harness.container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SizedBox(
            width: 1200,
            height: 800,
            child: ValueListenableBuilder<String?>(
              valueListenable: focused,
              builder: (_, key, __) => CanvasPresenceLayer(
                document: document,
                participants: roster,
                cameraViewFor: (id) => SizedBox(key: Key('camera-$id')),
                screenShareViewFor: (id) => SizedBox(key: Key('screen-$id')),
                overrides: overrides,
                onCommit: (_, __) {},
                onVideoInterest: interest.add,
                focusedKey: key,
                onFocus: (next) => focused.value = next,
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await controller.join('channel-1');
  session.emitState(VoiceSessionState.connected);
  await tester.pump();
  session.emitParticipants(roster);
  await tester.pumpAndSettle();

  return _Fixture(harness, session, document, interest, focused);
}

/// Reveals one tile's control row the way a desktop pointer does - the row
/// is hidden until hovered, pressed or focused (`canvas_presence_tile_reveal
/// _test.dart` owns that behaviour).
Future<void> _hover(WidgetTester tester, String key) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(gesture.removePointer);
  await gesture.addPointer(
    location: tester.getCenter(find.byKey(ValueKey(key))),
  );
  await tester.pump(AppMotion.fast);
}

/// One named tile's own expand control. Scoped to that tile rather than
/// matched by label alone: the row carries `alwaysIncludeSemantics`, so
/// every tile on the canvas answers the bare label whether revealed or not.
Finder _expandButton(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.bySemanticsLabel(_expandLabel),
);

void main() {
  testWidgets('a camera tile that is actually showing a camera offers a '
      'full-screen control', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');

    expect(_expandButton('camera:user-noor'), findsOneWidget);
    await fixture.leave();
  });

  testWidgets('a camera tile showing the avatar fallback offers none, since '
      'there is no feed to fill a screen with', (tester) async {
    final fixture = await _seated(
      tester,
      participants: [_camera('user-noor', 'Noor', on: false)],
    );
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');

    expect(
      _expandButton('camera:user-noor'),
      findsNothing,
      reason:
          'FullscreenVideoView pops itself the moment it opens on a feed '
          'that is not live, so offering the control would be a button that '
          'cannot work',
    );
    expect(
      find.byWidgetPredicate((w) => w is TileControls),
      findsOneWidget,
      reason:
          'the rest of the row must still be there - this asserts the '
          'expand button alone is gated, not that the tile lost its '
          'controls entirely',
    );
    await fixture.leave();
  });

  testWidgets('expanding a tile reports its key and opens no route over the '
      'canvas', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');
    await tester.tap(_expandButton('camera:user-noor'));
    await tester.pumpAndSettle();

    expect(fixture.focused.value, 'camera:user-noor');
    expect(find.byType(FullscreenVideoView), findsNothing);
    await fixture.leave();
  });

  testWidgets('a layer with nobody to focus for offers no expand control', (
    tester,
  ) async {
    final document = CanvasDocument()..setViewport(const Size(1200, 800));
    addTearDown(document.dispose);
    final overrides = CanvasPresenceTileOverrides();
    addTearDown(overrides.dispose);
    final harness = VoiceHarness();
    addTearDown(harness.dispose);
    final session = FakeSession();
    final controller = harness.controllerWith(session, voiceApi());
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: SizedBox(
              width: 1200,
              height: 800,
              child: CanvasPresenceLayer(
                document: document,
                participants: _roster,
                cameraViewFor: (id) => const SizedBox(),
                screenShareViewFor: (id) => const SizedBox(),
                overrides: overrides,
                onCommit: (_, __) {},
              ),
            ),
          ),
        ),
      ),
    );
    await controller.join('channel-1');
    session.emitState(VoiceSessionState.connected);
    await tester.pump();
    session.emitParticipants(_roster);
    await tester.pumpAndSettle();

    await _hover(tester, 'camera:user-noor');
    expect(_expandButton('camera:user-noor'), findsNothing);
    await harness.container.read(voiceControllerProvider.notifier).leave();
  });

  testWidgets('the focused tile is drawn by the pane, not here, and every '
      'tile stays subscribed', (tester) async {
    final fixture = await _seated(tester);
    addTearDown(fixture.harness.dispose);

    await _hover(tester, 'camera:user-noor');
    await tester.tap(_expandButton('camera:user-noor'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('camera:user-noor')), findsNothing);
    expect(find.byKey(const ValueKey('camera:user-ada')), findsOneWidget);
    expect(fixture.interest.last, {
      'camera:user-noor',
      'camera:user-ada',
      'camera:user-rex',
    }, reason: 'the others are still on the canvas over the feed');

    fixture.focused.value = null;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('camera:user-noor')), findsOneWidget);
    await fixture.leave();
  });
}
